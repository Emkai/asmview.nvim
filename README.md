# asmview.nvim

Side-by-side assembly view for C, C++ and Go. Compiles locally and highlights the assembly for the source line under the cursor (and the other way round).

## Install (lazy.nvim)

```lua
{
    "emkai/asmview.nvim",
    cmd = { "AsmView", "AsmCompare", "AsmSource" },
    keys = {
        { "<leader>aa", function() require("asmview").toggle() end, desc = "toggle assembly view" },
        { "<leader>ac", function() require("asmview").compare() end, desc = "toggle assembly compare pane" },
        { "<leader>as", function() require("asmview").source() end, desc = "pick assembly source for pane" },
        { "<leader>ae", function() require("asmview").ask() end, desc = "AI explain highlighted assembly" },
    },
    opts = {},
}
```

## Usage

`:AsmView` toggles the view. It refreshes on `:w` and follows you to other C, C++ and Go buffers. Highlighted assembly rows and the cursor row get an aligned `# ...` note saying what the instruction does with its operands, e.g. `# multiply xmm0 by [rsp+8] (double)` (x86, Go and ARM).

### Sources and panes

A source is one way of getting assembly for the current file. Each pane shows one source, so the same code can be put next to itself built another way: the binary your build produced, asmview's own compile, a different compile database, other flags, or a tweaked command.

```lua
sources = {
    firmware = { object = function(path) return path and (path:gsub("host", "target")) end },
    host = {},
    compile = { build = true },
    O0 = { build = true, extra_flags = { "-O0" } },
    clang = { build = true, args = function(args) args[1] = "clang" return args end },
    other_db = { build = true, compile_commands = "~/proj/build-arm" },
},
panes = { "firmware", "compile" },
```

A source takes the same keys as the top-level options, layered over them:

- `build`: `false` reads the object file from the build (`objdump`), `true` compiles the file.
- `object`: maps the object path from the compile database to the one to read.
- `compile_commands`: a `compile_commands.json` (or its folder) to take the command from instead of the one found next to the file.
- `extra_flags`: flags added after the project's own (the last `-O` wins).
- `args`: `function(args, file, entry)` that gets the compile command as a list and returns it changed.

`panes[1]` opens with `:AsmView`, `panes[2]` with `:AsmCompare`. The defaults are `output` (read the build output, compile if there is none) and `compile` (asmview compiles with the project flags).

Commands take a source name and/or extra flags, and change the pane in place when it is open:

- `:AsmView [source] [flags]`: the main pane.
- `:AsmCompare [source] [flags]`: the second pane (toggles it without arguments).
- `:AsmSource [source] [flags]`: the pane under the cursor. Without arguments it opens a picker.

For example `:AsmView O0` and `:AsmCompare compile -O3`. Flags make that pane compile. For Go they go into `-gcflags`, e.g. `:AsmCompare -N -l`.

`require("asmview").ask()` sends the highlighted assembly, its source line with `ai_context_lines` of surrounding code, and the function name to `ai_cmd` (default `claude -p`) and shows the answer in a popup. With the compare pane open it sends both versions and asks for the differences. Close the popup with `q` or `<Esc>`.

- C/C++: by default reads your build's object file with `objdump` (the `output`/`-o` from the file's `compile_commands.json` entry) and reloads when that file changes. The bar above the view shows which object it reads and warns when it is older than the source. Files with no compile entry are compiled by asmview. Set `build = true` to always compile the file itself. That mode uses the file's entry in `compile_commands.json` (searched upward, also in `build/` and the `CompilationDatabase` set in `.clangd`), so cross compilers and project flags just work. Without an entry it runs `cc`/`c++` with `c_fallback_flags`.
- Go: runs `go build -gcflags=-S` in the file's package and shows the functions defined in the file.

## Options

```lua
{
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
    sources = { output = {}, compile = { build = true } },
    panes = { "output", "compile" },
    compare_split = "below",
    c_fallback_flags = { "-O2" },
}
```

`objdump` is picked from the object's architecture (`arm-none-eabi-objdump` for ARM) unless set. Debug paths from another machine or container are matched to your file by their last folders. Top-level `build`, `object`, `extra_flags` and the rest apply to every source unless the source sets its own.
