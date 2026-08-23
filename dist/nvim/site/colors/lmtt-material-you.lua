-- hypr-DE: Material You colorscheme for Neovim.
-- Installed to /usr/share/nvim/site/colors/ (in Neovim's default runtimepath),
-- so it is selectable as `:colorscheme lmtt-material-you` by any user, but is
-- never forced. The palette itself is per-user: lmtt's hypr-de-nvim module
-- renders it to ~/.config/hypr-de/nvim-colors.lua on every theme switch.
local palette = vim.fn.expand("~/.config/hypr-de/nvim-colors.lua")
if vim.loop.fs_stat(palette) then
  vim.cmd.highlight("clear")
  dofile(palette)
else
  -- Palette not rendered yet (theme never applied): stay on the default
  -- scheme rather than leaving a half-cleared one.
  vim.notify("lmtt-material-you: run `lmtt switch` to render the palette", vim.log.levels.WARN)
end
