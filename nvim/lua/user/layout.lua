local cc = require("user.cc")

local M = {}

local ns = vim.api.nvim_create_namespace("user.layout")

local QUERIES = {
	c = [[
    [
      (struct_specifier name: (type_identifier) @name)
      (union_specifier  name: (type_identifier) @name)
    ] @decl
  ]],
	cpp = [[
    [
      (struct_specifier name: (type_identifier) @name)
      (union_specifier  name: (type_identifier) @name)
      (class_specifier  name: (type_identifier) @name)
    ] @decl
  ]],
}

--- size and align; C omits the dsize field that C++ emits, so match loosely
local function parse_clang(text)
	local out = {}
	for block in ("\n" .. text .. "\n\n"):gmatch("%*%*%* Dumping AST Record Layout(.-)\n%s*\n") do
		local name = block:match("|%s*[%w_]+%s+([%w_:]+)")
		local size, align = block:match("%[sizeof=(%d+),[^%]]-align=(%d+)")
		if name and size then
			out[name] = { size = tonumber(size), align = tonumber(align) }
		end
	end
	return out
end

local function parse_pahole(text)
	local out, cur = {}, nil
	for line in (text .. "\n"):gmatch("(.-)\n") do
		local name = line:match("^%s*[%w_]+%s+([%w_]+)%s*{")
		if name then
			cur = { waste = 0 }
			out[name] = cur
		elseif cur then
			local size = line:match("/%*%s*size:%s*(%d+)")
			local holes = line:match("sum holes:%s*(%d+)")
			local pad = line:match("/%*%s*padding:%s*(%d+)")
			if size then
				cur.size = tonumber(size)
			end
			if holes then
				cur.waste = cur.waste + tonumber(holes)
			end
			if pad then
				cur.waste = cur.waste + tonumber(pad)
			end
			if line:match("^%s*};") then
				cur = nil
			end
		end
	end
	return out
end

local function declarations(buf, ft)
	local ok, parser = pcall(vim.treesitter.get_parser, buf, ft)
	if not ok or not parser then
		return {}
	end
	local ok_q, query = pcall(vim.treesitter.query.parse, ft, QUERIES[ft])
	if not ok_q then
		return {}
	end

	local found = {}
	local tree = parser:parse()[1]
	for id, node in query:iter_captures(tree:root(), buf, 0, -1) do
		if query.captures[id] == "name" then
			local name = vim.treesitter.get_node_text(node, buf)
			local decl = node:parent()
			local row, col = decl:range()
			if not found[name] then
				found[name] = { row = row, col = col }
			end
		end
	end
	return found
end

local function place(buf, waste, layouts)
	if not vim.api.nvim_buf_is_valid(buf) then
		return
	end
	vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)

	for name, pos in pairs(declarations(buf, vim.bo[buf].filetype)) do
		local rec = layouts[name]
		if rec then
			local chunks = {
				{ (" "):rep(pos.col), "Comment" },
				{ ("%d bytes"):format(rec.size), "Comment" },
			}
			if rec.align then
				chunks[#chunks + 1] = { (" · align %d"):format(rec.align), "Comment" }
			end
			local lost = waste[name] and waste[name].waste or 0
			if lost > 0 then
				chunks[#chunks + 1] = { (" · %d wasted"):format(lost), "DiagnosticVirtualTextWarn" }
			end
			pcall(vim.api.nvim_buf_set_extmark, buf, ns, pos.row, 0, {
				virt_lines = { chunks },
				virt_lines_above = true,
			})
		end
	end
end

local inflight = {}

function M.refresh(buf)
	local ft = vim.bo[buf].filetype
	if not QUERIES[ft] or inflight[buf] then
		return
	end

	local path = vim.api.nvim_buf_get_name(buf)
	if path == "" or not vim.uv.fs_stat(path) then
		return
	end

	local argv, cwd = cc.base(path, ft)
	local obj = vim.fn.tempname() .. ".o"

	local dump = cc.clangify(argv, ft)
	vim.list_extend(dump, { "-Xclang", "-fdump-record-layouts-complete", "-fsyntax-only" })

	local build = vim.deepcopy(argv)
	vim.list_extend(build, { "-g", "-fno-eliminate-unused-debug-types", "-c", "-o", obj })

	inflight[buf] = true
	local layouts, waste = nil, nil
	local function done()
		if layouts and waste then
			inflight[buf] = nil
			vim.schedule(function()
				place(buf, waste, layouts)
			end)
		end
	end

	vim.system(dump, { cwd = cwd, text = true }, function(res)
		layouts = res.code == 0 and parse_clang(res.stdout or "") or {}
		done()
	end)

	vim.system(build, { cwd = cwd, text = true }, function(res)
		if res.code ~= 0 then
			waste = {}
			return done()
		end
		vim.system({ "pahole", obj }, { text = true }, function(ph)
			waste = ph.code == 0 and parse_pahole(ph.stdout or "") or {}
			vim.uv.fs_unlink(obj)
			done()
		end)
	end)
end

function M.setup()
	if vim.fn.executable("pahole") == 0 then
		return
	end

	vim.api.nvim_create_autocmd({ "BufReadPost", "BufWritePost" }, {
		group = vim.api.nvim_create_augroup("user-layout", { clear = true }),
		pattern = { "*.c", "*.h", "*.cpp", "*.cc", "*.cxx", "*.hpp", "*.hh" },
		callback = function(a)
			M.refresh(a.buf)
		end,
	})

	vim.api.nvim_create_user_command("StructSizes", function()
		M.refresh(vim.api.nvim_get_current_buf())
	end, { desc = "Recompute struct size hints" })
end

return M
