local M = {}

local noise = { TEXT = true, PCDATA = true, FUNCDATA = true }

function M.command(file, config)
    local gcflags = table.concat(vim.list_extend({ "-S" }, config.extra_flags or {}), " ")
    return {
        cmd = { "go", "build", "-gcflags=" .. gcflags, "-o", vim.fn.has("win32") == 1 and "NUL" or "/dev/null", "." },
        cwd = vim.fs.dirname(file),
        stream = "stderr",
    }
end

local function same(path, file)
    return (vim.uv.fs_realpath(path) or path) == file
end

function M.parse(output, file)
    local lines, src_to_asm, asm_to_src = {}, {}, {}
    local func, include

    for raw in output:gmatch("[^\n]*") do
        local sym, kind = raw:match("^(%S+) (S%u+)")
        if sym then
            func = kind == "STEXT" and sym or nil
            include = false
        elseif func then
            local offset, loc, instr = raw:match("^%s+0x%x+ (%d+) %((.-)%)%s+(.*)$")
            local path, line = (loc or ""):match("^(.*):(%d+)$")
            local op = instr and instr:match("^%S+")
            if op == "TEXT" and include == false then
                include = path ~= nil and same(path, file)
                if include then
                    if #lines > 0 then
                        table.insert(lines, "")
                    end
                    table.insert(lines, func .. ":")
                end
            end
            if include and offset and not noise[op] then
                table.insert(lines, string.format("    %5s  %s", offset, (instr:gsub("%s+", " "))))
                local src = path and same(path, file) and tonumber(line)
                if src then
                    asm_to_src[#lines] = src
                    src_to_asm[src] = src_to_asm[src] or {}
                    table.insert(src_to_asm[src], #lines)
                end
            end
        end
    end

    return { lines = lines, src_to_asm = src_to_asm, asm_to_src = asm_to_src, dialect = "go" }
end

return M
