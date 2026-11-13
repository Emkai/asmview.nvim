# asmview.nvim

Side-by-side assembly view for C, C++ and Go. Compiles locally and highlights the assembly for the source line under the cursor (and the other way round).

## Install (lazy.nvim)

```lua
{
    "emkai/asmview.nvim",
    cmd = "AsmView",
    keys = {
        { "<leader>aa", function() require("asmview").toggle() end, desc = "toggle assembly view" },
        { "<leader>ac", function() require("asmview").compare() end, desc = "toggle assembly compare pane" },
        { "<leader>ae", function() require("asmview").ask() end, desc = "AI explain highlighted assembly" },
    },
    opts = {},
}
```

## Usage

`:AsmView` toggles the view. It refreshes on `:w` and follows you to other C, C++ and Go buffers. Highlighted assembly rows and the cursor row get an aligned `# ...` note saying what the instruction does with its operands, e.g. `# multiply xmm0 by [rsp+8] (double)` (x86, Go and ARM).

`require("asmview").compare()` toggles a second assembly pane next to the first, set up by the `compare` option (merged over the main options). By default it compiles the file itself (`build = true`) while the main pane reads your build output, so you can put e.g. a firmware object next to a host build. Both panes highlight the same source line.

`require("asmview").ask()` sends the highlighted assembly, its source line with `ai_context_lines` of surrounding code, and the function name to `ai_cmd`. With the compare pane open it sends both versions and asks for the differences. (default `claude -p`) and shows the answer in a popup. Close it with `q` or `<Esc>`.

- C/C++: by default reads your build's object file with `objdump` (the `output`/`-o` from the file's `compile_commands.json` entry) and reloads when that file changes. The bar above the view shows which object it reads and warns when it is older than the source. Set `build = true` to compile the file itself instead. That mode uses the file's entry in `compile_commands.json` (searched upward, also in `build/` and the `CompilationDatabase` set in `.clangd`), so cross compilers and project flags just work. Without an entry it runs `cc`/`c++` with `c_fallback_flags`.
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
    objdump = nil,
    object = nil,
    compare = { build = true },
    c_fallback_flags = { "-O2" },
}
```

`objdump` is picked from the object's architecture (`arm-none-eabi-objdump` for ARM) unless set. Debug paths from another machine or container are matched to your file by their last folders. `object` maps the path from the compile database to the object to read, e.g. to show a firmware build instead of a host build:

```lua
object = function(path) return (path:gsub("application_sil", "application")) end
```
