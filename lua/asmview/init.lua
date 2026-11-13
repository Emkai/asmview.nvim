local M = {}

local config = {
    highlight = "Visual",
    explain = true,
    explain_highlight = "Comment",
    ai_cmd = { "claude", "-p" },
    ai_prompt = "Below is the assembly the compiler generated for the source line marked >>, with the surrounding code for context. Explain in a short summary what the assembly does.",
    ai_context_lines = 20,
    c_fallback_flags = { "-O2" },
}

local backends = {
    c = "asmview.c",
    cpp = "asmview.c",
    go = "asmview.go",
}

local ns = vim.api.nvim_create_namespace("asmview")
local group_name = "asmview"
local state

function M.setup(opts)
    config = vim.tbl_deep_extend("force", config, opts or {})
end

local function clear()
    for _, buf in ipairs({ state.src_buf, state.asm_buf }) do
        if vim.api.nvim_buf_is_valid(buf) then
            vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
        end
    end
end

local function note(line)
    local text = config.explain and state.notes[line]
    if not text then
        return {}
    end
    return { virt_text = { { "# " .. text, config.explain_highlight } }, virt_text_win_col = state.note_col }
end

local function mark(buf, line)
    local opts = { line_hl_group = config.highlight }
    if buf == state.asm_buf then
        opts = vim.tbl_extend("force", opts, note(line))
    end
    vim.api.nvim_buf_set_extmark(buf, ns, line - 1, 0, opts)
end

local function reveal(buf, line)
    local win = vim.fn.bufwinid(buf)
    if win == -1 then
        return
    end
    vim.api.nvim_win_call(win, function()
        if line < vim.fn.line("w0") or line > vim.fn.line("w$") then
            vim.api.nvim_win_set_cursor(win, { line, 0 })
            vim.cmd("normal! zz")
        end
    end)
end

local function show_src_line(line)
    clear()
    local asm_lines = state.src_to_asm[line]
    if not asm_lines then
        return
    end
    for _, l in ipairs(asm_lines) do
        mark(state.asm_buf, l)
    end
    return asm_lines
end

local function sync_from_src()
    local asm_lines = show_src_line(vim.api.nvim_win_get_cursor(0)[1])
    if asm_lines then
        reveal(state.asm_buf, asm_lines[1])
    end
end

local function sync_from_asm()
    local line = vim.api.nvim_win_get_cursor(0)[1]
    local src_line = state.asm_to_src[line]
    if not src_line then
        clear()
        if state.notes[line] then
            vim.api.nvim_buf_set_extmark(state.asm_buf, ns, line - 1, 0, note(line))
        end
        return
    end
    show_src_line(src_line)
    mark(state.src_buf, src_line)
    reveal(state.src_buf, src_line)
end

local function build()
    local s = state
    local backend = require(backends[s.filetype])
    local job, err = backend.command(s.file, config, s.filetype)
    if not job then
        vim.notify("asmview: " .. err, vim.log.levels.ERROR)
        return
    end
    vim.system(job.cmd, { cwd = job.cwd, text = true }, vim.schedule_wrap(function(res)
        if state ~= s or not vim.api.nvim_buf_is_valid(s.asm_buf) then
            return
        end
        if res.code ~= 0 then
            vim.notify("asmview: build failed\n" .. (res.stderr or ""), vim.log.levels.ERROR)
            return
        end
        local out = job.stream == "stderr" and res.stderr or res.stdout
        local result = backend.parse(out, s.file, job.cwd)
        vim.bo[s.asm_buf].modifiable = true
        vim.api.nvim_buf_set_lines(s.asm_buf, 0, -1, false, result.lines)
        vim.bo[s.asm_buf].modifiable = false
        s.src_to_asm = result.src_to_asm
        s.asm_to_src = result.asm_to_src
        local explain = require("asmview.explain")
        local dialect = result.dialect or explain.dialect(result.lines)
        s.notes, s.note_col = {}, 0
        for i, l in ipairs(result.lines) do
            s.note_col = math.max(s.note_col, vim.fn.strdisplaywidth(l))
            s.notes[i] = explain.line(l, dialect)
        end
        s.note_col = s.note_col + 4
        if vim.api.nvim_get_current_buf() == s.src_buf then
            sync_from_src()
        elseif vim.api.nvim_get_current_buf() == s.asm_buf then
            sync_from_asm()
        end
    end))
end

local function cleanup()
    if not state then
        return
    end
    clear()
    state = nil
    pcall(vim.api.nvim_del_augroup_by_name, group_name)
end

function M.close()
    if state and vim.api.nvim_buf_is_valid(state.asm_buf) then
        vim.api.nvim_buf_delete(state.asm_buf, { force = true })
    end
    cleanup()
end

function M.open()
    local src_buf = vim.api.nvim_get_current_buf()
    local filetype = vim.bo[src_buf].filetype
    if not backends[filetype] then
        vim.notify("asmview: unsupported filetype " .. filetype, vim.log.levels.WARN)
        return
    end
    local file = vim.api.nvim_buf_get_name(src_buf)
    if file == "" then
        vim.notify("asmview: buffer has no file", vim.log.levels.WARN)
        return
    end
    file = vim.uv.fs_realpath(file) or file

    local src_win = vim.api.nvim_get_current_win()
    local asm_buf = vim.api.nvim_create_buf(false, true)
    vim.bo[asm_buf].filetype = "asm"
    vim.bo[asm_buf].bufhidden = "wipe"
    vim.bo[asm_buf].modifiable = false
    vim.api.nvim_buf_set_name(asm_buf, "asmview://" .. vim.fs.basename(file))

    local asm_win = vim.api.nvim_open_win(asm_buf, false, { split = "right", win = src_win })
    vim.wo[asm_win].wrap = false

    state = {
        src_buf = src_buf,
        asm_buf = asm_buf,
        file = file,
        filetype = filetype,
        src_to_asm = {},
        asm_to_src = {},
        notes = {},
        note_col = 0,
    }

    local group = vim.api.nvim_create_augroup(group_name, { clear = true })
    vim.api.nvim_create_autocmd("CursorMoved", { group = group, buffer = src_buf, callback = sync_from_src })
    vim.api.nvim_create_autocmd("CursorMoved", { group = group, buffer = asm_buf, callback = sync_from_asm })
    vim.api.nvim_create_autocmd("BufWritePost", { group = group, buffer = src_buf, callback = build })
    vim.api.nvim_create_autocmd("BufWipeout", { group = group, buffer = asm_buf, callback = cleanup })

    build()
end

local function popup(lines, title)
    local width = math.min(90, vim.o.columns - 4)
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].filetype = "markdown"
    vim.bo[buf].bufhidden = "wipe"
    local height = 0
    for _, l in ipairs(lines) do
        height = height + math.max(1, math.ceil(vim.fn.strdisplaywidth(l) / width))
    end
    height = math.min(height, vim.o.lines - 6)
    local win = vim.api.nvim_open_win(buf, true, {
        relative = "editor",
        width = width,
        height = height,
        row = math.floor((vim.o.lines - height) / 2) - 1,
        col = math.floor((vim.o.columns - width) / 2),
        border = "rounded",
        title = " " .. title .. " ",
        title_pos = "center",
        style = "minimal",
    })
    vim.wo[win].wrap = true
    vim.wo[win].linebreak = true
    for _, key in ipairs({ "q", "<Esc>" }) do
        vim.keymap.set("n", key, function()
            pcall(vim.api.nvim_win_close, win, true)
        end, { buffer = buf, nowait = true })
    end
    vim.api.nvim_create_autocmd("WinLeave", {
        buffer = buf,
        once = true,
        callback = function()
            pcall(vim.api.nvim_win_close, win, true)
        end,
    })
end

local function selection()
    local buf = vim.api.nvim_get_current_buf()
    local line = vim.api.nvim_win_get_cursor(0)[1]
    local src_line, asm_lines
    if buf == state.src_buf then
        src_line = line
    elseif buf == state.asm_buf then
        src_line = state.asm_to_src[line]
        if not src_line then
            asm_lines = { line }
        end
    else
        return
    end
    asm_lines = asm_lines or state.src_to_asm[src_line]
    if not asm_lines then
        return
    end
    local asm = {}
    for _, l in ipairs(asm_lines) do
        table.insert(asm, vim.trim(vim.api.nvim_buf_get_lines(state.asm_buf, l - 1, l, false)[1] or ""))
    end
    local func
    for l = asm_lines[1], 1, -1 do
        local label = vim.api.nvim_buf_get_lines(state.asm_buf, l - 1, l, false)[1]:match("^([^%s.][^%s]*):$")
        if label then
            func = label
            break
        end
    end
    return src_line, asm, func
end

local function context(src_line)
    if not src_line then
        return "(unknown)"
    end
    local n = config.ai_context_lines
    local first = math.max(1, src_line - n)
    local out = {}
    for i, l in ipairs(vim.api.nvim_buf_get_lines(state.src_buf, first - 1, src_line + n, false)) do
        local num = first + i - 1
        table.insert(out, string.format("%s%5d  %s", num == src_line and ">>" or "  ", num, l))
    end
    return table.concat(out, "\n")
end

function M.ask()
    if not state then
        vim.notify("asmview: open the view first", vim.log.levels.WARN)
        return
    end
    local src_line, asm, func = selection()
    if not asm then
        vim.notify("asmview: no assembly for this line", vim.log.levels.WARN)
        return
    end
    local where = vim.fs.basename(state.file) .. (src_line and ":" .. src_line or "")
    local prompt = config.ai_prompt
        .. "\n\nFile: " .. state.file .. (src_line and ", line " .. src_line or "")
        .. (func and "\nFunction: " .. func or "")
        .. "\n\nSource (" .. state.filetype .. "):\n" .. context(src_line)
        .. "\n\nAssembly:\n" .. table.concat(asm, "\n")
    local cmd = vim.deepcopy(config.ai_cmd)
    table.insert(cmd, prompt)
    vim.notify("asmview: asking " .. cmd[1] .. "...")
    local ok, err = pcall(vim.system, cmd, { text = true }, vim.schedule_wrap(function(res)
        if res.code ~= 0 then
            vim.notify("asmview: " .. cmd[1] .. " failed\n" .. (res.stderr or ""), vim.log.levels.ERROR)
            return
        end
        popup(vim.split(vim.trim(res.stdout or ""), "\n"), where)
    end))
    if not ok then
        vim.notify("asmview: " .. err, vim.log.levels.ERROR)
    end
end

function M.toggle()
    if state then
        M.close()
    else
        M.open()
    end
end

return M
