local cfg = vim.fn.stdpath("config")
for _, f in ipairs({ "/init.lua", "/init.vim" }) do
  if vim.loop.fs_stat(cfg .. f) then
    return
  end
end

vim.opt.termguicolors = true
vim.opt.number = true
vim.opt.mouse = "a"
vim.opt.ignorecase = true
vim.opt.smartcase = true
vim.opt.undofile = true
vim.opt.clipboard = "unnamedplus"

if vim.loop.fs_stat(vim.fn.expand("~/.config/hypr-de/nvim-colors.lua")) then
  pcall(vim.cmd.colorscheme, "lmtt-material-you")
end
