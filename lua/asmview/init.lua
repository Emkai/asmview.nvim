local M = {}

local config = {
    highlight = "Visual",
    explain = true,
    explain_highlight = "Comment",
    c_fallback_flags = { "-O2" },
}

local backends = {
    c = "asmview.c",
    cpp = "asmview.c",
    go = "asmview.go",
}

local ns = vim.api.nvim_create_namespace("asmview")
local explain_ns = vim.api.nvim_create_namespace("asmview_explain")
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

local function mark(buf, line)
    vim.api.nvim_buf_set_extmark(buf, ns, line - 1, 0, { line_hl_group = config.highlight })
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

local function clear_explain()
    if state and vim.api.nvim_buf_is_valid(state.asm_buf) then
        vim.api.nvim_buf_clear_namespace(state.asm_buf, explain_ns, 0, -1)
    end
end

local function show_explain()
    clear_explain()
    if not config.explain then
        return
    end
    local row = vim.api.nvim_win_get_cursor(0)[1] - 1
    local text = vim.api.nvim_buf_get_lines(state.asm_buf, row, row + 1, false)[1]
    local desc = text and require("asmview.explain").line(text)
    if desc then
        vim.api.nvim_buf_set_extmark(state.asm_buf, explain_ns, row, 0, {
            virt_text = { { "    " .. desc, config.explain_highlight } },
            virt_text_pos = "eol",
        })
    end
end

local function sync_from_asm()
    show_explain()
    local src_line = state.asm_to_src[vim.api.nvim_win_get_cursor(0)[1]]
    if not src_line then
        clear()
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
        if vim.api.nvim_get_current_buf() == s.src_buf then
            sync_from_src()
        elseif vim.api.nvim_get_current_buf() == s.asm_buf then
            show_explain()
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
    }

    local group = vim.api.nvim_create_augroup(group_name, { clear = true })
    vim.api.nvim_create_autocmd("CursorMoved", { group = group, buffer = src_buf, callback = sync_from_src })
    vim.api.nvim_create_autocmd("CursorMoved", { group = group, buffer = asm_buf, callback = sync_from_asm })
    vim.api.nvim_create_autocmd("BufLeave", { group = group, buffer = asm_buf, callback = clear_explain })
    vim.api.nvim_create_autocmd("BufWritePost", { group = group, buffer = src_buf, callback = build })
    vim.api.nvim_create_autocmd("BufWipeout", { group = group, buffer = asm_buf, callback = cleanup })

    build()
end

function M.toggle()
    if state then
        M.close()
    else
        M.open()
    end
end

return M
