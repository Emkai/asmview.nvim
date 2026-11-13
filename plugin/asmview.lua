local function complete(lead)
    return require("asmview").complete(lead)
end

vim.api.nvim_create_user_command("AsmView", function(opts)
    if #opts.fargs > 0 then
        require("asmview").open(opts.fargs)
    else
        require("asmview").toggle()
    end
end, { nargs = "*", complete = complete, desc = "Toggle assembly view, or set its source and extra flags" })

vim.api.nvim_create_user_command("AsmCompare", function(opts)
    require("asmview").compare(opts.fargs)
end, { nargs = "*", complete = complete, desc = "Toggle compare pane, or set its source and extra flags" })

vim.api.nvim_create_user_command("AsmSource", function(opts)
    require("asmview").source(opts.fargs)
end, { nargs = "*", complete = complete, desc = "Pick the source for the assembly pane under the cursor" })
