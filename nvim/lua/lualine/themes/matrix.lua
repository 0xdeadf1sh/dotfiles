local black = "#000000"
local bg1 = "#011508"
local bg3 = "#063d16"
local dim = "#0b6b26"
local mid = "#159a38"
local fg = "#20c84a"
local bright = "#00ff41"
local mint = "#c0ffd0"
local white = "#e0ffe8"
local red = "#ff3b3b"
local amber = "#ffb000"

local function mode(color)
	return {
		a = { fg = black, bg = color, gui = "bold" },
		b = { fg = color, bg = bg3 },
		c = { fg = fg, bg = bg1 },
	}
end

return {
	normal = mode(bright),
	insert = mode(mint),
	visual = mode(white),
	replace = mode(red),
	command = mode(amber),
	terminal = mode(mid),
	inactive = {
		a = { fg = dim, bg = black },
		b = { fg = dim, bg = black },
		c = { fg = dim, bg = black },
	},
}
