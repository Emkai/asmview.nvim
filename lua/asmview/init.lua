local M = {}

local config = {
    highlight = "Visual",
    explain = true,
    explain_highlight = "Comment",
    ai_cmd = { "claude", "-p" },
    ai_prompt = "Below is the assembly the compiler generated for the source line marked >>, with the surrounding code for context. Explain in a short summary what the assembly does.",
    ai_context_lines = 20,
    build = false,
    extra_flags = {},
    objdump = nil,
    object = nil,
    compare = { build = true },
    compare_split = "below",
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

local function view_of(buf)
    for _, v in ipairs(state.views) do
        if v.buf == buf then
            return v
        end
    end
end

local function clear()
    for _, buf in ipairs(vim.list_extend({ state.src_buf }, vim.tbl_map(function(v)
        return v.buf
    end, state.views))) do
        if buf and vim.api.nvim_buf_is_valid(buf) then
            vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
        end
    end
end

local function note(v, line)
    local text = config.explain and v.notes[line]
    if not text then
        return {}
    end
    return { virt_text = { { "# " .. text, config.explain_highlight } }, virt_text_win_col = v.note_col }
end

local function mark_asm(v, line, hl)
    local opts = note(v, line)
    if hl then
        opts.line_hl_group = config.highlight
    end
    if next(opts) then
        vim.api.nvim_buf_set_extmark(v.buf, ns, line - 1, 0, opts)
    end
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

local function show_src_line(line, except)
    clear()
    for _, v in ipairs(state.views) do
        local asm_lines = v.src_to_asm[line]
        if asm_lines then
            for _, l in ipairs(asm_lines) do
                mark_asm(v, l, true)
            end
            if v ~= except then
                reveal(v.buf, asm_lines[1])
            end
        end
    end
end

local function sync_from_src()
    show_src_line(vim.api.nvim_win_get_cursor(0)[1])
end

local function sync_from_asm(v)
    local line = vim.api.nvim_win_get_cursor(0)[1]
    local src_line = v.asm_to_src[line]
    if not src_line then
        clear()
        mark_asm(v, line, false)
        return
    end
    show_src_line(src_line, v)
    vim.api.nvim_buf_set_extmark(state.src_buf, ns, src_line - 1, 0, { line_hl_group = config.highlight })
    reveal(state.src_buf, src_line)
end

local function set_view(v, lines, winbar)
    vim.bo[v.buf].modifiable = true
    vim.api.nvim_buf_set_lines(v.buf, 0, -1, false, lines)
    vim.bo[v.buf].modifiable = false
    local win = vim.fn.bufwinid(v.buf)
    if win ~= -1 then
        vim.wo[win].winbar = winbar or ""
    end
end

local build

local function unwatch(v)
    if v.watcher then
        v.watcher:close()
        v.watcher = nil
    end
end

local function watch(v, path)
    if v.watched == path then
        return
    end
    unwatch(v)
    v.watched = path
    if not path then
        return
    end
    local w = vim.uv.new_fs_event()
    if not w then
        return
    end
    local name = vim.fs.basename(path)
    local timer
    w:start(vim.fs.dirname(path), {}, function(_, fname)
        if fname ~= name then
            return
        end
        if timer then
            timer:stop()
            timer:close()
        end
        timer = vim.defer_fn(function()
            timer = nil
            if state and view_of(v.buf) == v and v.watched == path then
                build(v)
            end
        end, 300)
    end)
    v.watcher = w
end

local function stale(obj, file)
    local o, f = vim.uv.fs_stat(obj), vim.uv.fs_stat(file)
    return o and f and f.mtime.sec > o.mtime.sec
end

build = function(v)
    local s = state
    v.gen = (v.gen or 0) + 1
    local gen, file = v.gen, s.file
    local backend = require(backends[s.filetype])
    local job, err, missing = backend.command(s.file, v.cfg, s.filetype)
    watch(v, job and job.object or missing)
    if not job then
        v.src_to_asm, v.asm_to_src, v.notes = {}, {}, {}
        clear()
        set_view(v, { "asmview: " .. err })
        return
    end
    vim.system(job.cmd, { cwd = job.cwd, text = true }, vim.schedule_wrap(function(res)
        if state ~= s or v.gen ~= gen or view_of(v.buf) ~= v or not vim.api.nvim_buf_is_valid(v.buf) then
            return
        end
        if res.code ~= 0 then
            set_view(v, vim.split("asmview: " .. job.cmd[1] .. " failed\n" .. (res.stderr or ""), "\n"))
            return
        end
        local out = job.stream == "stderr" and res.stderr or res.stdout
        local result = (job.parse or backend.parse)(out, file, job.cwd)
        local winbar
        if job.object then
            v.label = vim.fn.fnamemodify(job.object, ":~:.")
            winbar = " " .. v.label
            if stale(job.object, file) then
                winbar = winbar .. "  %#WarningMsg#(older than source)"
            end
        else
            v.label = "built by asmview" .. (#(v.cfg.extra_flags or {}) > 0 and " " .. table.concat(v.cfg.extra_flags, " ") or "")
            winbar = " " .. v.label
        end
        set_view(v, result.lines, winbar)
        v.src_to_asm = result.src_to_asm
        v.asm_to_src = result.asm_to_src
        local explain = require("asmview.explain")
        local dialect = result.dialect or explain.dialect(result.lines)
        v.notes, v.note_col = {}, 0
        for i, l in ipairs(result.lines) do
            v.note_col = math.max(v.note_col, vim.fn.strdisplaywidth(l))
            v.notes[i] = explain.line(l, dialect)
        end
        v.note_col = v.note_col + 4
        local cur = vim.api.nvim_get_current_buf()
        if cur == s.src_buf then
            sync_from_src()
        elseif view_of(cur) then
            sync_from_asm(view_of(cur))
        end
    end))
end

local function build_all()
    for _, v in ipairs(state.views) do
        build(v)
    end
end

local function cleanup()
    if not state then
        return
    end
    local s = state
    clear()
    state = nil
    pcall(vim.api.nvim_del_augroup_by_name, group_name)
    for _, v in ipairs(s.views) do
        unwatch(v)
        if vim.api.nvim_buf_is_valid(v.buf) then
            vim.api.nvim_buf_delete(v.buf, { force = true })
        end
    end
end

function M.close()
    cleanup()
end

local function source_file(buf)
    if not backends[vim.bo[buf].filetype] or vim.bo[buf].buftype ~= "" then
        return
    end
    local file = vim.api.nvim_buf_get_name(buf)
    if file == "" then
        return
    end
    return vim.uv.fs_realpath(file) or file
end

local function name_view(v)
    pcall(vim.api.nvim_buf_set_name, v.buf, v.scheme .. "://" .. vim.fs.basename(state.file))
end

local function attach(buf, file)
    clear()
    state.src_buf = buf
    state.file = file
    state.filetype = vim.bo[buf].filetype
    for _, v in ipairs(state.views) do
        v.src_to_asm, v.asm_to_src, v.notes = {}, {}, {}
        name_view(v)
        set_view(v, { "loading " .. vim.fs.basename(file) .. "..." })
    end
    build_all()
end

local function new_view(cfg, scheme, win, split)
    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].filetype = "asm"
    vim.bo[buf].bufhidden = "wipe"
    vim.bo[buf].modifiable = false
    local asm_win = vim.api.nvim_open_win(buf, false, { split = split or "right", win = win })
    vim.wo[asm_win].wrap = false
    local v = { buf = buf, cfg = cfg, scheme = scheme, src_to_asm = {}, asm_to_src = {}, notes = {}, note_col = 0 }
    table.insert(state.views, v)
    vim.api.nvim_create_autocmd("BufWipeout", {
        group = group_name,
        buffer = buf,
        callback = function()
            if not state then
                return
            end
            if state.views[1] == v then
                vim.schedule(cleanup)
                return
            end
            unwatch(v)
            state.views = vim.tbl_filter(function(x)
                return x ~= v
            end, state.views)
        end,
    })
    return v
end

local function with_flags(cfg, flags)
    if not flags or #flags == 0 then
        return cfg
    end
    return vim.tbl_extend("force", cfg, { build = true, extra_flags = flags })
end

function M.open(flags)
    if state then
        if flags and #flags > 0 then
            state.views[1].cfg = with_flags(config, flags)
            build(state.views[1])
        end
        return
    end
    local src_buf = vim.api.nvim_get_current_buf()
    local file = source_file(src_buf)
    if not file then
        vim.notify("asmview: unsupported buffer (" .. vim.bo[src_buf].filetype .. ")", vim.log.levels.WARN)
        return
    end

    state = { views = {} }
    local group = vim.api.nvim_create_augroup(group_name, { clear = true })
    new_view(with_flags(config, flags), "asmview", vim.api.nvim_get_current_win())

    vim.api.nvim_create_autocmd("CursorMoved", {
        group = group,
        callback = function(args)
            if args.buf == state.src_buf then
                sync_from_src()
            elseif view_of(args.buf) then
                sync_from_asm(view_of(args.buf))
            end
        end,
    })
    vim.api.nvim_create_autocmd("BufWritePost", {
        group = group,
        callback = function(args)
            if args.buf == state.src_buf then
                build_all()
            end
        end,
    })
    vim.api.nvim_create_autocmd("BufEnter", {
        group = group,
        callback = function(args)
            if args.buf == state.src_buf or view_of(args.buf) then
                return
            end
            local f = source_file(args.buf)
            if f then
                attach(args.buf, f)
            end
        end,
    })

    attach(src_buf, file)
end

function M.compare(flags)
    if not state then
        M.open()
        if not state then
            return
        end
    end
    local cfg = with_flags(vim.tbl_deep_extend("force", config, config.compare or {}), flags)
    if state.views[2] then
        if flags and #flags > 0 then
            state.views[2].cfg = cfg
            build(state.views[2])
        else
            vim.api.nvim_buf_delete(state.views[2].buf, { force = true })
        end
        return
    end
    local main_win = vim.fn.bufwinid(state.views[1].buf)
    local v = new_view(cfg, "asmview-compare", main_win, config.compare_split)
    name_view(v)
    set_view(v, { "loading " .. vim.fs.basename(state.file) .. "..." })
    build(v)
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

local function asm_text(v, lines)
    local out = {}
    for _, l in ipairs(lines) do
        table.insert(out, vim.trim(vim.api.nvim_buf_get_lines(v.buf, l - 1, l, false)[1] or ""))
    end
    local func
    for l = lines[1], 1, -1 do
        local label = (vim.api.nvim_buf_get_lines(v.buf, l - 1, l, false)[1] or ""):match("^([^%s.][^%s]*):$")
        if label then
            func = label
            break
        end
    end
    return table.concat(out, "\n"), func
end

local function selection()
    local buf = vim.api.nvim_get_current_buf()
    local line = vim.api.nvim_win_get_cursor(0)[1]
    local here = view_of(buf)
    local src_line
    if buf == state.src_buf then
        src_line = line
    elseif here then
        src_line = here.asm_to_src[line]
        if not src_line then
            local text, func = asm_text(here, { line })
            return nil, { { label = here.label, text = text } }, func
        end
    else
        return
    end
    local parts, func = {}, nil
    for _, v in ipairs(state.views) do
        local lines = v.src_to_asm[src_line]
        if lines then
            local text, f = asm_text(v, lines)
            func = func or f
            table.insert(parts, { label = v.label, text = text })
        end
    end
    if #parts == 0 then
        return
    end
    return src_line, parts, func
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
    local src_line, parts, func = selection()
    if not parts then
        vim.notify("asmview: no assembly for this line", vim.log.levels.WARN)
        return
    end
    local where = vim.fs.basename(state.file) .. (src_line and ":" .. src_line or "")
    local prompt = config.ai_prompt
    if #parts > 1 then
        prompt = prompt .. " The same source was compiled for different targets; compare the versions and point out meaningful differences."
    end
    prompt = prompt
        .. "\n\nFile: " .. state.file .. (src_line and ", line " .. src_line or "")
        .. (func and "\nFunction: " .. func or "")
        .. "\n\nSource (" .. state.filetype .. "):\n" .. context(src_line)
    for _, p in ipairs(parts) do
        prompt = prompt .. "\n\nAssembly (" .. (p.label or "?") .. "):\n" .. p.text
    end
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
