local flags = { "-O0", "-O1", "-O2", "-O3", "-Os", "-Oz", "-Og", "-march=native", "-fno-inline", "-funroll-loops", "-ffast-math" }

local function complete(lead)
    return vim.tbl_filter(function(f)
        return f:sub(1, #lead) == lead
    end, flags)
end

vim.api.nvim_create_user_command("AsmView", function(opts)
    if #opts.fargs > 0 then
        require("asmview").open(opts.fargs)
    else
        require("asmview").toggle()
    end
end, { nargs = "*", complete = complete, desc = "Toggle assembly view, or rebuild it with extra compiler flags" })

vim.api.nvim_create_user_command("AsmCompare", function(opts)
    require("asmview").compare(opts.fargs)
end, { nargs = "*", complete = complete, desc = "Toggle compare pane, or rebuild it with extra compiler flags" })
