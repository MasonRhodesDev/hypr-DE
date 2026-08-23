-- hypr-DE Neovim baseline. Loaded from /usr/share/nvim/site/plugin/ (Neovim's
-- default runtimepath) instead of /etc/xdg/nvim/sysinit.vim, which the neovim
-- package owns on Arch -- shipping that path is a hard pacman file conflict.
--
-- Deliberately minimal, and it yields completely: if you have any Neovim
-- config of your own, this file does nothing at all. Your ~/.config/nvim wins,
-- exactly like ~/.config/hypr/local.lua does for the compositor.
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

-- Apply the Material You scheme when lmtt has rendered a palette. pcall so a
-- missing or malformed file can never break `nvim` for the user.
if vim.loop.fs_stat(vim.fn.expand("~/.config/hypr-de/nvim-colors.lua")) then
  pcall(vim.cmd.colorscheme, "lmtt-material-you")
end
