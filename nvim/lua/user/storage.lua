local cc = require("user.cc")

local M = {}

local FT = { c = true, cpp = true, rust = true }

local HEAP = {
	"new%s",
	"new$",
	"malloc%s*%(",
	"calloc%s*%(",
	"realloc%s*%(",
	"strdup%s*%(",
	"make_unique",
	"make_shared",
	"Box::new",
	"Vec::new",
	"vec!",
	"String::from",
	"to_string%s*%(",
	"to_vec%s*%(",
	"Rc::new",
	"Arc::new",
}

local SECTION = {
	b = "bss",
	B = "bss",
	d = "data",
	D = "data",
	r = "rodata",
	R = "rodata",
	g = "data (small)",
	G = "data (small)",
	s = "bss (small)",
	S = "bss (small)",
	t = "text",
	T = "text",
}

local cache = {}

local function warn(msg)
	vim.notify("storage: " .. msg, vim.log.levels.WARN)
end

local function num(v)
	if not v then
		return nil
	end
	local hex = v:match("^0x(%x+)")
	return hex and tonumber(hex, 16) or tonumber(v:match("^(%d+)"))
end

local function str(v)
	return v and v:match('"([^"]*)"')
end

local function parse_dies(text)
	local dies, cur = {}, nil
	for line in (text .. "\n"):gmatch("(.-)\n") do
		local off, tag = line:match("^(0x%x+):%s+(DW_TAG_[%w_]+)")
		if off then
			cur = { offset = off, tag = tag, attrs = {} }
			dies[#dies + 1] = cur
		elseif cur then
			local k, v = line:match("^%s+(DW_AT_[%w_]+)%s+%((.*)%)%s*$")
			if k then
				cur.attrs[k] = v
			end
		end
	end
	return dies
end

local function dwarf(obj, args, cb)
	local argv = { "llvm-dwarfdump" }
	vim.list_extend(argv, args)
	argv[#argv + 1] = obj
	vim.system(argv, { text = true }, function(res)
		cb(res.code == 0 and parse_dies(res.stdout or "") or {})
	end)
end

local addr_size = {}

local function address_size(obj, cb)
	if addr_size[obj] then
		return cb(addr_size[obj])
	end
	vim.system({ "llvm-dwarfdump", "--debug-info", obj }, { text = true }, function(res)
		local n = tonumber((res.stdout or ""):match("addr_size%s*=%s*0x(%x+)") or "", 16) or 8
		addr_size[obj] = n
		cb(n)
	end)
end

local POINTER = { DW_TAG_pointer_type = true, DW_TAG_reference_type = true, DW_TAG_rvalue_reference_type = true }

--- byte_size and, when derivable, alignment; follows typedef, const, pointer and array chains
local function resolve_type(obj, offset, seen, cb)
	seen = seen or 0
	if not offset or seen > 8 then
		return cb(nil)
	end
	dwarf(obj, { "--debug-info=" .. offset, "--show-children" }, function(dies)
		local d = dies[1]
		if not d then
			return cb(nil)
		end
		local size = num(d.attrs.DW_AT_byte_size)
		local align = num(d.attrs.DW_AT_alignment)
		local name = str(d.attrs.DW_AT_name)
		local inner = d.attrs.DW_AT_type and d.attrs.DW_AT_type:match("^(0x%x+)")

		if size then
			-- a scalar or pointer is aligned to its own width on this ABI
			local natural = d.tag == "DW_TAG_base_type" or POINTER[d.tag]
			return cb({
				size = size,
				align = align or (natural and size or nil),
				name = name,
				tag = d.tag,
				inner = inner,
			})
		end

		-- rustc emits pointers with no byte_size, so fall back to the unit's address size
		if POINTER[d.tag] then
			return address_size(obj, function(n)
				cb({ size = n, align = align or n, name = name, tag = d.tag, inner = inner })
			end)
		end

		if d.tag == "DW_TAG_array_type" then
			local count = 1
			for i = 2, #dies do
				if dies[i].tag == "DW_TAG_subrange_type" then
					local c = num(dies[i].attrs.DW_AT_count)
					local ub = num(dies[i].attrs.DW_AT_upper_bound)
					count = count * (c or (ub and ub + 1) or 1)
				end
			end
			return resolve_type(obj, inner, seen + 1, function(el)
				if not el then
					return cb(nil)
				end
				cb({ size = el.size * count, align = align or el.align, name = name, tag = d.tag })
			end)
		end

		resolve_type(obj, inner, seen + 1, function(t)
			if t and (d.tag == "DW_TAG_typedef" or d.tag == "DW_TAG_const_type") then
				t.name = name or t.name
			end
			cb(t)
		end)
	end)
end

local function build(path, ft)
	local obj = vim.fn.tempname() .. ".o"
	if ft == "rust" then
		local cargo = vim.fs.find("Cargo.toml", { path = vim.fs.dirname(path), upward = true, type = "file" })[1]
		local flags = { "-g", "-Copt-level=0", "-Ccodegen-units=1", "--emit", "obj=" .. obj }
		if cargo then
			local argv = { "cargo", "rustc", "--quiet", "--" }
			vim.list_extend(argv, flags)
			return argv, vim.fs.dirname(cargo), obj
		end
		local argv = { "rustc" }
		vim.list_extend(argv, flags)
		argv[#argv + 1] = path
		return argv, vim.fs.dirname(path), obj
	end
	local argv, cwd = cc.base(path, ft)
	vim.list_extend(argv, { "-g", "-O0", "-c", "-o", obj })
	return argv, cwd, obj
end

local function object(path, ft, cb)
	local st = vim.uv.fs_stat(path)
	local mtime = st and st.mtime.sec or 0
	local hit = cache[path]
	if hit and hit.mtime == mtime and vim.uv.fs_stat(hit.obj) then
		return cb(hit.obj)
	end

	local argv, cwd, obj = build(path, ft)
	vim.system(argv, { cwd = cwd, text = true }, function(res)
		if res.code ~= 0 or not vim.uv.fs_stat(obj) then
			return cb(nil, vim.trim((res.stderr or ""):sub(1, 200)))
		end
		cache[path] = { mtime = mtime, obj = obj }
		cb(obj)
	end)
end

local function section_of(obj, name, linkage, cb)
	vim.system({ "nm", "-C", "--print-size", "--defined-only", obj }, { text = true }, function(res)
		local want = linkage or name
		for line in ((res.stdout or "") .. "\n"):gmatch("(.-)\n") do
			local size, class, sym = line:match("^%x*%s*(%x*)%s+(%a)%s+(.+)$")
			if sym and (sym == want or sym:match("::" .. vim.pesc(name) .. "$")) then
				return cb(SECTION[class] or class, tonumber(size, 16))
			end
		end
		cb(nil)
	end)
end

local function heap_init(line)
	for _, p in ipairs(HEAP) do
		if line:find(p) then
			return true
		end
	end
	return false
end

local function present(lines)
	vim.lsp.util.open_floating_preview(lines, "markdown", {
		border = "rounded",
		focusable = false,
		max_width = 72,
	})
end

local function bytes(n)
	return ("%d byte%s"):format(n, n == 1 and "" or "s")
end

function M.show()
	local buf = vim.api.nvim_get_current_buf()
	local ft = vim.bo[buf].filetype
	if not FT[ft] then
		return warn("no backend for '" .. ft .. "'")
	end

	local path = vim.api.nvim_buf_get_name(buf)
	if path == "" or not vim.uv.fs_stat(path) then
		return warn("buffer has no file on disk")
	end

	local name = vim.fn.expand("<cword>")
	if name == "" then
		return
	end

	local decl_line = vim.fn.line(".")
	local params = vim.lsp.util.make_position_params(0, "utf-16")
	local defs = vim.lsp.buf_request_sync(buf, "textDocument/definition", params, 700) or {}
	for _, r in pairs(defs) do
		local d = r.result and (r.result[1] or r.result)
		local range = d and (d.range or d.targetSelectionRange)
		if range then
			decl_line = range.start.line + 1
		end
	end

	local src = vim.api.nvim_buf_get_lines(buf, decl_line - 1, decl_line, false)[1] or ""

	object(path, ft, function(obj, err)
		if not obj then
			return vim.schedule(function()
				warn("build failed: " .. (err or "?"))
			end)
		end

		dwarf(obj, { "--name=" .. name }, function(dies)
			local var, type_die
			for _, d in ipairs(dies) do
				if d.tag == "DW_TAG_variable" or d.tag == "DW_TAG_formal_parameter" then
					if not var or num(d.attrs.DW_AT_decl_line) == decl_line then
						var = var and num(d.attrs.DW_AT_decl_line) == decl_line and d or var or d
					end
				elseif not type_die and d.attrs.DW_AT_byte_size then
					type_die = d
				end
			end

			if not var and not type_die then
				return vim.schedule(function()
					warn("'" .. name .. "' not in the debug info")
				end)
			end

			if not var then
				local size = num(type_die.attrs.DW_AT_byte_size)
				local align = num(type_die.attrs.DW_AT_alignment)
				local function say(a)
					vim.schedule(function()
						present({ ("**%s** — %s%s"):format(name, bytes(size), a and (" · align " .. a) or "") })
					end)
				end
				if align or ft == "rust" then
					return say(align)
				end
				return cc.layouts(path, ft, function(recs)
					say(recs[name] and recs[name].align)
				end)
			end

			local tref = var.attrs.DW_AT_type and var.attrs.DW_AT_type:match("^(0x%x+)")
			local tname = str(var.attrs.DW_AT_type) or "?"

			resolve_type(obj, tref, 0, function(t)
				local loc = var.attrs.DW_AT_location or ""
				local linkage = str(var.attrs.DW_AT_linkage_name)

				local function finish(where, extra)
					local head = ("**%s** `%s`"):format(name, tname)
					local sz = t and bytes(t.size) or "size unknown"
					local al = t and t.align and (" · align " .. t.align) or ""
					local lines = { head, ("%s%s · %s"):format(sz, al, where) }
					if extra then
						lines[#lines + 1] = extra
					end
					vim.schedule(function()
						present(lines)
					end)
				end

				local plain_finish = finish
				finish = function(where, extra)
					if not t or t.align or ft == "rust" or not t.name then
						return plain_finish(where, extra)
					end
					cc.layouts(path, ft, function(recs)
						local r = recs[t.name]
						if r then
							t.align = r.align
						end
						plain_finish(where, extra)
					end)
				end

				local function with_heap(where)
					if t and t.tag == "DW_TAG_pointer_type" and heap_init(src) then
						return resolve_type(obj, t.inner, 0, function(pointee)
							finish(where, pointee and ("→ %s on **heap**"):format(bytes(pointee.size)) or nil)
						end)
					end
					finish(where)
				end

				if loc:match("DW_OP_addr") then
					section_of(obj, name, linkage, function(sec)
						with_heap("**" .. (sec or "static") .. "**")
					end)
				elseif loc:match("DW_OP_fbreg") then
					local off = loc:match("DW_OP_fbreg%s+([%+%-]?%d+)")
					with_heap(("**stack** (frame %s)"):format(off or "?"))
				elseif loc:match("DW_OP_reg") then
					with_heap("**register**")
				elseif loc == "" then
					with_heap("optimized out")
				else
					with_heap(loc)
				end
			end)
		end)
	end)
end

function M.setup()
	if vim.fn.executable("llvm-dwarfdump") == 0 then
		return
	end
	vim.keymap.set("n", "gK", M.show, { desc = "Size, alignment and storage of the symbol under the cursor" })
end

return M
