" hypr-DE system Neovim config. Neovim sources this (the first
" $XDG_CONFIG_DIRS/nvim/sysinit.vim) before user config, so it is the
" package-owned baseline; ~/.config/nvim overrides everything here.
lua << LUA
-- Minimal, deliberately not a distro: sane defaults + lmtt Material You.
vim.opt.termguicolors = true
vim.opt.number = true
vim.opt.mouse = "a"
vim.opt.ignorecase = true
vim.opt.smartcase = true
vim.opt.undofile = true
vim.opt.clipboard = "unnamedplus"
-- Material You palette rendered by the hypr-de-nvim lmtt module. pcall so a
-- missing/not-yet-rendered file never aborts startup.
pcall(dofile, vim.fn.expand("~/.config/hypr-de/nvim-colors.lua"))
LUA
