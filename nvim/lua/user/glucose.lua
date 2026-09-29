local utils = require("lualine.utils.utils")

local M = require("lualine.component"):extend()

local DIR = vim.fs.joinpath(vim.env.XDG_STATE_HOME or vim.fs.joinpath(vim.env.HOME, ".local/state"), "t1dmkde")

local runs = {}
local timer, watcher

local function parse(s)
	s = s:gsub("[\1\2]", "")
	local out, fg, dim, i = {}, nil, false, 1
	while i <= #s do
		local a, b, codes = s:find("\27%[([%d;]*)m", i)
		local text = s:sub(i, (a or #s + 1) - 1)
		if text ~= "" then
			out[#out + 1] = { text = text, fg = fg, dim = dim }
		end
		if not a then
			break
		end
		local r, g, bl = codes:match("^38;2;(%d+);(%d+);(%d+)$")
		if r then
			fg = ("#%02x%02x%02x"):format(tonumber(r), tonumber(g), tonumber(bl))
		elseif codes == "2" then
			dim = true
		else
			fg, dim = nil, false
		end
		i = b + 1
	end
	return out
end

local function refresh()
	pcall(vim.system, { "t1dmkd", "prompt" }, { text = true }, function(res)
		vim.schedule(function()
			runs = res.code == 0 and parse(res.stdout or "") or {}
			require("lualine").refresh()
		end)
	end)
end

local function start()
	if timer or vim.fn.executable("t1dmkd") == 0 then
		return
	end
	timer = vim.uv.new_timer()
	timer:start(0, 30000, vim.schedule_wrap(refresh))
	-- the daemon writes the snapshot by rename, so watch the directory, not the file
	watcher = vim.uv.new_fs_event()
	watcher:start(DIR, {}, function(err, name)
		if not err and name == "snapshot.json" then
			vim.schedule(refresh)
		end
	end)
end

function M:init(options)
	options.component_name = options.component_name or "glucose"
	M.super.init(self, options)
	self.hls = {}
	start()
end

function M:hl(key)
	if not self.hls[key] then
		local fg = key == "dim" and utils.extract_highlight_colors("Comment", "fg") or key
		self.hls[key] = self:create_hl({ fg = fg }, (key:gsub("#", "")))
	end
	return self:format_hl(self.hls[key])
end

function M:update_status()
	local s = {}
	for _, r in ipairs(runs) do
		local key = r.fg or (r.dim and "dim")
		s[#s + 1] = (key and self:hl(key) or self:get_default_hl()) .. r.text
	end
	return table.concat(s)
end

return M
