# asmview.nvim

Side-by-side assembly view for C, C++ and Go. Compiles locally and highlights the assembly for the source line under the cursor (and the other way round).

## Install (lazy.nvim)

```lua
{
    "emkai/asmview.nvim",
    cmd = "AsmView",
    keys = { { "<leader>a", function() require("asmview").toggle() end, desc = "toggle assembly view" } },
    opts = {},
}
```

## Usage

`:AsmView` toggles the view. It rebuilds on `:w`. Highlighted assembly rows and the cursor row get an aligned `# ...` note saying what the instruction does with its operands, e.g. `# multiply xmm0 by [rsp+8] (double)` (x86, Go and ARM).

- C/C++: uses the file's entry in `compile_commands.json` (searched upward, also in `build/` and the `CompilationDatabase` set in `.clangd`), so cross compilers and project flags just work. Without an entry it runs `cc`/`c++` with `c_fallback_flags`.
- Go: runs `go build -gcflags=-S` in the file's package and shows the functions defined in the file.

## Options

```lua
{
    highlight = "Visual",
    explain = true,
    explain_highlight = "Comment",
    c_fallback_flags = { "-O2" },
}
```
