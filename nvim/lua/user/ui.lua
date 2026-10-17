local M = {}

function M.geometry(max_w, max_h)
	local w = math.min(max_w or 100, math.floor(vim.o.columns * 0.8))
	local h = math.min(max_h or 40, math.floor(vim.o.lines * 0.8))
	return {
		relative = "editor",
		width = w,
		height = h,
		row = math.floor((vim.o.lines - h) / 2) - 1,
		col = math.floor((vim.o.columns - w) / 2),
		style = "minimal",
		border = "rounded",
	}
end

--- a float has no winbar, so the status rides on the border
function M.retitle(win, title, max_w, max_h)
	if not (win and vim.api.nvim_win_is_valid(win)) then
		return
	end
	local cfg = M.geometry(max_w, max_h)
	cfg.title = " " .. title .. " "
	cfg.title_pos = "left"
	vim.api.nvim_win_set_config(win, cfg)
end

function M.render(buf, lines)
	vim.bo[buf].modifiable = true
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.bo[buf].modifiable = false
	vim.bo[buf].modified = false
end

return M
