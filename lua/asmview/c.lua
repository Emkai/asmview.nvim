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

local function find_db(file)
    for dir in vim.fs.parents(file) do
        for _, candidate in ipairs({ dir .. "/compile_commands.json", dir .. "/build/compile_commands.json" }) do
            if vim.uv.fs_stat(candidate) then
                return candidate
            end
        end
    end
end

local function find_entry(file)
    local db = find_db(file)
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
    vim.list_extend(out, asm_flags)
    return out
end

function M.command(file, config, filetype)
    local entry = find_entry(file)
    if entry then
        local args = entry.arguments or shell_split(entry.command)
        return { cmd = rewrite(args), cwd = entry.directory, stream = "stdout" }
    end
    local compiler = filetype == "cpp" and "c++" or "cc"
    local cmd = { compiler }
    vim.list_extend(cmd, config.c_fallback_flags)
    vim.list_extend(cmd, asm_flags)
    table.insert(cmd, file)
    return { cmd = cmd, cwd = vim.fs.dirname(file), stream = "stdout" }
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
