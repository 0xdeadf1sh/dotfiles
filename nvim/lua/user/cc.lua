local M = {}

local function find_up(from, name)
	return vim.fs.find(name, { path = from, upward = true, type = "file" })[1]
end

---@return table? entry from compile_commands.json describing `path`
function M.db_entry(path)
	local dirs = { find_up(vim.fs.dirname(path), "compile_commands.json") }
	local root = vim.fs.root(path, { ".git", "CMakeLists.txt", "Makefile", "meson.build" })
	if root then
		for _, sub in ipairs({ "build", "out", "builddir" }) do
			dirs[#dirs + 1] = root .. "/" .. sub .. "/compile_commands.json"
		end
	end

	local want = vim.fs.normalize(path)
	for _, db in ipairs(dirs) do
		if db and vim.uv.fs_stat(db) then
			local ok, data = pcall(vim.json.decode, table.concat(vim.fn.readfile(db), "\n"))
			if ok and type(data) == "table" then
				for _, e in ipairs(data) do
					local f = e.file or ""
					if not vim.startswith(f, "/") then
						f = (e.directory or ".") .. "/" .. f
					end
					if vim.fs.normalize(f) == want then
						return e
					end
				end
			end
		end
	end
end

local DROP_PAIR = { ["-o"] = true, ["-MF"] = true, ["-MT"] = true, ["-MQ"] = true }
local DROP = { ["-c"] = true, ["-MD"] = true, ["-MMD"] = true, ["-MP"] = true, ["-S"] = true }

local function strip(args)
	local out, skip = {}, false
	for _, a in ipairs(args) do
		if skip then
			skip = false
		elseif DROP_PAIR[a] then
			skip = true
		elseif not (DROP[a] or a:match("^%-O") or a:match("^%-g%d?$")) then
			out[#out + 1] = a
		end
	end
	return out
end

---@return string[] argv, string cwd — output, optimization and dependency flags removed
function M.base(path, ft)
	local e = M.db_entry(path)
	if e then
		return strip(e.arguments or vim.split(e.command or "", "%s+", { trimempty = true })), e.directory
	end
	return {
		ft == "cpp" and "c++" or "cc",
		ft == "cpp" and "-std=c++23" or "-std=c23",
		path,
	}, vim.fs.dirname(path)
end

--- Same argv with the driver swapped for clang, which owns the AST dump flags
function M.clangify(argv, ft)
	local out = vim.deepcopy(argv)
	out[1] = ft == "cpp" and "clang++" or "clang"
	return out
end

return M
