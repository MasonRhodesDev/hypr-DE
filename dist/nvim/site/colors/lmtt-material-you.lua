local palette = vim.fn.expand("~/.config/hypr-de/nvim-colors.lua")
if vim.loop.fs_stat(palette) then
  vim.cmd.highlight("clear")
  dofile(palette)
else
  vim.notify("lmtt-material-you: run `lmtt switch` to render the palette", vim.log.levels.WARN)
end
