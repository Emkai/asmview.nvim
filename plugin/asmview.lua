vim.api.nvim_create_user_command("AsmView", function()
    require("asmview").toggle()
end, { desc = "Toggle side-by-side assembly view" })
