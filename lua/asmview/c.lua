local M = {}

local asm_flags = { "-S", "-g", "-fno-asynchronous-unwind-tables", "-o", "-" }

local function realpath(path)
    return vim.uv.fs_realpath(path) or vim.fs.normalize(path)
end

local function shell_split(cmd)
    local args, cur, quote, i = {}, nil, nil, 1
    while i <= #cmd do
        local ch = cmd:sub(i, i)
        if quote then
            if ch == quote then
                quote = nil
            elseif ch == "\\" and quote == '"' and i < #cmd then
                i = i + 1
                cur = cur .. cmd:sub(i, i)
            else
                cur = cur .. ch
            end
        elseif ch == "'" or ch == '"' then
            quote = ch
            cur = cur or ""
        elseif ch == "\\" and i < #cmd then
            i = i + 1
            cur = (cur or "") .. cmd:sub(i, i)
        elseif ch:match("%s") then
            if cur then
                table.insert(args, cur)
                cur = nil
            end
        else
            cur = (cur or "") .. ch
        end
        i = i + 1
    end
    if cur then
        table.insert(args, cur)
    end
    return args
end

local function clangd_db(dir)
    local f = io.open(dir .. "/.clangd")
    if not f then
        return
    end
    local text = f:read("*a")
    f:close()
    local path = text:match("CompilationDatabase:%s*['\"]?([^'\"\n#]-)['\"]?%s*\n")
        or text:match("CompilationDatabase:%s*['\"]?([^'\"\n#]-)['\"]?%s*$")
    if not path or path == "" or path == "None" or path == "Ancestors" then
        return
    end
    if path:sub(1, 1) ~= "/" then
        path = dir .. "/" .. path
    end
    return path .. "/compile_commands.json"
end

local function find_db(file)
    for dir in vim.fs.parents(file) do
        local candidates = { dir .. "/compile_commands.json", dir .. "/build/compile_commands.json" }
        local from_clangd = clangd_db(dir)
        if from_clangd then
            table.insert(candidates, 1, from_clangd)
        end
        for _, candidate in ipairs(candidates) do
            if vim.uv.fs_stat(candidate) then
                return candidate
            end
        end
    end
end

local function find_entry(file, override)
    local db = find_db(file)
    if override then
        db = vim.fn.expand(override)
        if vim.fn.isdirectory(db) == 1 then
            db = db .. "/compile_commands.json"
        end
        if not vim.uv.fs_stat(db) then
            return nil
        end
    end
    if not db then
        return
    end
    local ok, entries = pcall(vim.json.decode, table.concat(vim.fn.readfile(db), "\n"))
    if not ok or type(entries) ~= "table" then
        return
    end
    for _, e in ipairs(entries) do
        local path = e.file
        if path:sub(1, 1) ~= "/" then
            path = e.directory .. "/" .. path
        end
        if realpath(path) == file then
            return e
        end
    end
end

local drop_with_value = { ["-o"] = true, ["-MF"] = true, ["-MT"] = true, ["-MQ"] = true }
local drop = { ["-c"] = true, ["-MD"] = true, ["-MMD"] = true, ["-M"] = true, ["-MM"] = true }
local launchers = { ccache = true, sccache = true }

local function rewrite(args)
    local out, skip = {}, false
    for i, arg in ipairs(args) do
        if skip then
            skip = false
        elseif i == 1 and launchers[vim.fs.basename(arg)] then
        elseif drop_with_value[arg] then
            skip = true
        elseif not (drop[arg] or arg:match("^%-o.") or arg:match("^%-flto")) then
            table.insert(out, arg)
        end
    end
    return out
end

local function object_path(entry)
    local out = entry.output
    if not out then
        local args = entry.arguments or shell_split(entry.command)
        for i, a in ipairs(args) do
            if a == "-o" then
                out = args[i + 1]
            elseif a:match("^%-o.") then
                out = a:sub(3)
            end
        end
    end
    if out and out:sub(1, 1) ~= "/" then
        out = entry.directory .. "/" .. out
    end
    return out
end

local function objdump_for(obj, config)
    if config.objdump then
        return config.objdump
    end
    local f = io.open(obj, "rb")
    local head = f and f:read(20) or ""
    if f then
        f:close()
    end
    local machine = #head >= 20 and head:byte(19) + head:byte(20) * 256
    if machine == 0x28 and vim.fn.executable("arm-none-eabi-objdump") == 1 then
        return "arm-none-eabi-objdump"
    elseif machine == 0xB7 and vim.fn.executable("aarch64-linux-gnu-objdump") == 1 then
        return "aarch64-linux-gnu-objdump"
    end
    return "objdump"
end

local function build_command(file, config, filetype, entry)
    local cmd, cwd
    if entry then
        cmd, cwd = rewrite(entry.arguments or shell_split(entry.command)), entry.directory
    else
        cmd, cwd = { filetype == "cpp" and "c++" or "cc" }, vim.fs.dirname(file)
        vim.list_extend(cmd, config.c_fallback_flags)
        table.insert(cmd, file)
    end
    vim.list_extend(cmd, config.extra_flags or {})
    if config.args then
        cmd = config.args(cmd, file, entry) or cmd
    end
    vim.list_extend(cmd, asm_flags)
    return { cmd = cmd, cwd = cwd, stream = "stdout" }
end

function M.command(file, config, filetype)
    local entry = find_entry(file, config.compile_commands)
    if config.build then
        return build_command(file, config, filetype, entry)
    end
    local obj = entry and object_path(entry)
    if config.object then
        local ok, mapped = pcall(config.object, obj, file, entry)
        if not ok then
            return nil, "object option failed: " .. tostring(mapped)
        end
        obj = mapped
    end
    if not obj then
        return build_command(file, config, filetype, entry)
    end
    if not vim.uv.fs_stat(obj) then
        return nil, "no object file at " .. obj .. " (build the project, or set build = true)", obj
    end
    return {
        cmd = { objdump_for(obj, config), "-drlw", "--no-show-raw-insn", obj },
        cwd = entry and entry.directory or vim.fs.dirname(obj),
        stream = "stdout",
        parse = M.parse_objdump,
        object = obj,
    }
end

local function short_sym(sym)
    return (sym:gsub("^%.%a+%.([%a_])", "%1"))
end

local function resolve(reloc, next_addr)
    local name, sign, hex = reloc.sym:match("^(.-)([%+%-])0x(%x+)$")
    local add = 0
    if name then
        add = tonumber(hex, 16) * (sign == "-" and -1 or 1)
    else
        name = reloc.sym
    end
    if reloc.type:match("^R_X86_64_") and (reloc.type:match("PC") or reloc.type:match("PLT")) then
        add = add + ((next_addr or reloc.addr + 4) - reloc.addr)
    end
    name = short_sym(name)
    if add > 0 then
        return name .. "+" .. add
    elseif add < 0 then
        return name .. add
    end
    return name
end

function M.parse_objdump(output, file, cwd)
    local rows, pool = {}, {}
    local section, current = "", nil
    local cache = {}
    local function same(path)
        if cache[path] == nil then
            local full = path:sub(1, 1) == "/" and path or cwd .. "/" .. path
            local match = realpath(full) == file
            if not match and vim.fs.basename(path) == vim.fs.basename(file) then
                local parts = vim.split(path, "/", { trimempty = true })
                local tail = table.concat(parts, "/", math.max(1, #parts - 3))
                match = #parts >= 2 and file:sub(-#tail - 1) == "/" .. tail
            end
            cache[path] = match
        end
        return cache[path]
    end

    for l in output:gmatch("[^\n]*") do
        local sec = l:match("^Disassembly of section (%S+):")
        local func = l:match("^%x+ <(.+)>:$")
        local raddr, rtype, rsym = l:match("^%s+(%x+):%s+(R_[%w_]+)%s+(%S+)$")
        local path, ln = l:match("^(%S.-):(%d+) %(discriminator %d+%)$")
        if not path then
            path, ln = l:match("^(%S.-):(%d+)$")
        end
        if sec then
            section, current = sec, nil
        elseif func then
            table.insert(rows, { label = func })
        elseif raddr then
            pool[section .. ":" .. tonumber(raddr, 16)] = short_sym(rsym)
        elseif path and not l:match("^%x+ <") then
            current = same(path) and tonumber(ln) or nil
        else
            local addr, text = l:match("^%s*(%x+):%s+(.+)$")
            if addr then
                local row = { section = section, addr = tonumber(addr, 16), src = current }
                local body, ra, rt, rs = text:match("^(.-)\t(%x+): (R_[%w_]+)\t(%S+)$")
                if body then
                    text = body
                    row.reloc = { addr = tonumber(ra, 16), type = rt, sym = rs }
                end
                row.pc_target = text:match("@ %(?(%x+) <")
                text = text:gsub("%s+# .*$", ""):gsub("%s+@ .*$", ""):gsub("%s+", " ")
                row.text = vim.trim(text)
                table.insert(rows, row)
            end
        end
    end

    local lines, src_to_asm, asm_to_src = {}, {}, {}
    for i, row in ipairs(rows) do
        if row.label then
            if #lines > 0 then
                table.insert(lines, "")
            end
            table.insert(lines, row.label .. ":")
        else
            local text = row.text
            local nxt = rows[i + 1]
            if row.reloc then
                local sym = resolve(row.reloc, nxt and nxt.section == row.section and nxt.addr or nil)
                if text:find("(%rip)", 1, true) then
                    text = text:gsub("%-?0x%x+%(%%rip%)", sym .. "(%%rip)", 1)
                elseif text:find("%x+ <[^>]*>") then
                    text = text:gsub("%x+ <[^>]*>", sym, 1)
                elseif text:find("%$0x0") then
                    text = text:gsub("%$0x0", "$" .. sym, 1)
                else
                    text = text .. " <" .. sym .. ">"
                end
            elseif text:match("^%.word") and pool[row.section .. ":" .. row.addr] then
                text = ".word " .. pool[row.section .. ":" .. row.addr]
            end
            if row.pc_target then
                local sym = pool[row.section .. ":" .. tonumber(row.pc_target, 16)]
                text = text:gsub("%[pc, #%-?%d+%]", sym and "=" .. sym or "[" .. row.pc_target .. "]", 1)
            end
            text = text:gsub("(%x+) <[^>]*>", "%1")
            table.insert(lines, string.format("%6x:  %s", row.addr, text))
            if row.src then
                asm_to_src[#lines] = row.src
                src_to_asm[row.src] = src_to_asm[row.src] or {}
                table.insert(src_to_asm[row.src], #lines)
            end
        end
    end
    return { lines = lines, src_to_asm = src_to_asm, asm_to_src = asm_to_src }
end

local function quoted(s)
    local parts = {}
    for q in s:gmatch('"(.-)"') do
        table.insert(parts, q)
    end
    return parts
end

local function keep_label(label)
    return label:sub(1, 1) ~= "." or label:match("^%.L%d+$") or label:match("^%.LBB%d+_%d+$")
end

function M.parse(output, file, cwd)
    local lines, src_to_asm, asm_to_src = {}, {}, {}
    local files, comp_dir = {}, cwd
    local current, in_text = nil, true

    for raw in output:gmatch("[^\n]*") do
        local trimmed = vim.trim(raw)
        local num, rest = trimmed:match("^%.file%s+(%d+)%s+(.*)$")
        if num then
            local q = quoted(rest)
            local path
            if #q >= 2 then
                path = q[2]:sub(1, 1) == "/" and q[2] or q[1] .. "/" .. q[2]
            elseif q[1] then
                path = q[1]:sub(1, 1) == "/" and q[1] or comp_dir .. "/" .. q[1]
            end
            if path then
                files[num] = realpath(path) == file
                if num == "0" and #q >= 2 then
                    comp_dir = q[1]
                end
            end
        elseif trimmed:match("^%.loc%s") then
            local n, l = trimmed:match("^%.loc%s+(%d+)%s+(%d+)")
            current = files[n] and tonumber(l) ~= 0 and tonumber(l) or nil
        elseif trimmed == ".text" then
            in_text = true
        elseif trimmed:match("^%.data") or trimmed:match("^%.bss") then
            in_text = false
        elseif trimmed:match("^%.section%s") then
            in_text = trimmed:match("^%.section%s+%.text") ~= nil
        elseif in_text and trimmed ~= "" then
            local label = trimmed:match("^([%w_.$@]+):$")
            if label then
                if keep_label(label) then
                    if label:sub(1, 1) ~= "." and #lines > 0 then
                        table.insert(lines, "")
                    end
                    table.insert(lines, label .. ":")
                end
            elseif not trimmed:match("^[.#@;]") and not trimmed:match("^//") then
                table.insert(lines, "    " .. (trimmed:gsub("%s+", " ")))
                if current then
                    local n = #lines
                    asm_to_src[n] = current
                    src_to_asm[current] = src_to_asm[current] or {}
                    table.insert(src_to_asm[current], n)
                end
            end
        end
    end

    return { lines = lines, src_to_asm = src_to_asm, asm_to_src = asm_to_src }
end

return M
