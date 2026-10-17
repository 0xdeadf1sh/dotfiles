local ui = require("user.ui")

local M = {}

local ns = vim.api.nvim_create_namespace("user.perf")
local STORE = vim.fn.stdpath("state") .. "/perf.json"
local MARKERS = { "Cargo.toml", "premake5.lua", "meson.build", "CMakeLists.txt", "Makefile" }

-- perf and llvm-symbolizer otherwise fetch debug info for every system DSO over the network
local ENV = { DEBUGINFOD_URLS = "" }

-- a release build with line tables, without touching Cargo.toml
local CARGO_PROFILE = "--config 'profile.profiling.inherits=\"release\"' --config profile.profiling.debug=true"

local PRECISE = { "cycles:pp", "instructions:pp", "mem_load_retired.l3_miss:pp", "br_misp_retired.all_branches:pp" }
local GENERIC = { "cycles", "instructions", "cache-misses", "branch-misses" }
local ALIAS = {
	cycles = "cycles",
	instructions = "insns",
	["mem_load_retired.l3_miss"] = "llc",
	["cache-misses"] = "llc",
	["br_misp_retired.all_branches"] = "br",
	["branch-misses"] = "br",
}
local SHOWN = { "cycles", "llc", "br" }
local LABEL = { cycles = "cycles", llc = "LLC misses", br = "branch misses" }

local EIGHTHS = { "▏", "▎", "▍", "▌", "▋", "▊", "▉" }
local SPARK = { " ", "▁", "▂", "▃", "▄", "▅", "▆", "▇", "█" }
local DEPTH = 8

-- 128 KiB ring buffer per CPU; perf's default fills the per-user perf_event_mlock_kb budget alone
local MMAP_PAGES = "32"
local KEYS = "[e] event  [p] pin  [R] rerun  [c] config  [q] close"
local KEYS_ATTACHED = "[e] event  [R] reattach  [c] process  [q] close"

local state = {}
-- the float whose perf record is running; only one at a time fits the locked-memory budget
local recording

local function warn(msg)
	vim.notify("perf: " .. msg, vim.log.levels.WARN)
end

local function resume(co, ...)
	local ok, err = coroutine.resume(co, ...)
	if not ok then
		vim.notify("perf: " .. debug.traceback(co, err), vim.log.levels.ERROR)
	end
end

--- every yield resumes on the main loop, so the body may call any API
local function spawn(fn)
	resume(coroutine.create(fn))
end

local function sh(argv, opts, hold)
	local co = coroutine.running()
	opts = vim.tbl_extend("keep", opts or {}, { text = true, env = ENV })
	local ok, obj = pcall(vim.system, argv, opts, function(res)
		vim.schedule(function()
			resume(co, res)
		end)
	end)
	if not ok then
		return { code = -1, stdout = "", stderr = tostring(obj) }
	end
	if hold then
		hold(obj)
	end
	return coroutine.yield()
end

local function input(prompt, default)
	local co = coroutine.running()
	vim.ui.input({ prompt = prompt, default = default }, function(v)
		vim.schedule(function()
			resume(co, v)
		end)
	end)
	return coroutine.yield()
end

local function choose(items, prompt, format)
	local co = coroutine.running()
	vim.ui.select(items, { prompt = prompt, format_item = format }, function(v)
		vim.schedule(function()
			resume(co, v)
		end)
	end)
	return coroutine.yield()
end

local realpaths = {}

local function real(p)
	if realpaths[p] == nil then
		realpaths[p] = vim.uv.fs_realpath(p) or vim.fs.normalize(p)
	end
	return realpaths[p]
end

local function abs(base, p)
	return vim.startswith(p, "/") and p or base .. "/" .. p
end

local function q(s)
	return s:match("^[%w%./_%-+=:,@]+$") and s or vim.fn.shellescape(s)
end

local function rel(root, p)
	return vim.fs.relpath(root, p) or p
end

--- "./" so the shell runs the file instead of searching PATH
local function exe(root, p)
	local r = vim.fs.relpath(root, p)
	return q(r and "./" .. r or p)
end

local function read_json(f)
	local ok, data = pcall(function()
		return vim.json.decode(table.concat(vim.fn.readfile(f), "\n"))
	end)
	return ok and type(data) == "table" and data or nil
end

local function load()
	return read_json(STORE) or {}
end

local function save(root, cfg)
	local all = load()
	all[root] = cfg
	vim.fn.mkdir(vim.fs.dirname(STORE), "p")
	vim.fn.writefile({ vim.json.encode(all) }, STORE)
end

local function project_root(path)
	return vim.fs.root(path, ".git") or vim.fs.root(path, MARKERS) or vim.fs.dirname(path)
end

local function build_dirs(root, path)
	local dirs = {}
	local db = vim.fs.find("compile_commands.json", { path = vim.fs.dirname(path), upward = true })[1]
	if db then
		dirs[#dirs + 1] = vim.fs.dirname(real(db))
	end
	for _, sub in ipairs({ "build", "out", "builddir", "_build" }) do
		dirs[#dirs + 1] = root .. "/" .. sub
	end
	vim.list_extend(dirs, vim.fn.glob(root .. "/cmake-build-*", false, true))
	return dirs
end

local function cargo(root, path)
	local manifest = vim.fs.find("Cargo.toml", { path = vim.fs.dirname(path), upward = true })[1]
	if not manifest then
		return
	end
	local res = sh({ "cargo", "metadata", "--format-version", "1", "--no-deps", "--manifest-path", manifest })
	local ok, meta = pcall(vim.json.decode, res.stdout or "")
	if res.code ~= 0 or not ok then
		return
	end
	local out = {}
	for _, pkg in ipairs(meta.packages) do
		for _, t in ipairs(pkg.targets) do
			if vim.tbl_contains(t.kind, "bin") then
				out[#out + 1] = {
					name = t.name,
					owns = real(t.src_path) == path,
					build = ("cargo build --manifest-path %s --profile profiling -p %s --bin %s %s"):format(
						q(rel(root, pkg.manifest_path)),
						pkg.name,
						t.name,
						CARGO_PROFILE
					),
					run = exe(root, vim.fs.joinpath(meta.target_directory, "profiling", t.name)),
				}
			end
		end
	end
	return out
end

local function cmake(root, path)
	if not vim.uv.fs_stat(root .. "/CMakeLists.txt") then
		return
	end
	local dir
	for _, d in ipairs(build_dirs(root, path)) do
		if vim.uv.fs_stat(d .. "/CMakeCache.txt") then
			dir = d
			break
		end
	end
	if not dir then
		return
	end

	local query = dir .. "/.cmake/api/v1/query/codemodel-v2"
	vim.fn.mkdir(vim.fs.dirname(query), "p")
	vim.fn.writefile({}, query)
	if sh({ "cmake", dir }).code ~= 0 then
		return
	end

	local reply = dir .. "/.cmake/api/v1/reply/"
	local index = vim.fn.glob(reply .. "index-*.json", false, true)
	table.sort(index)
	local model
	for _, o in ipairs((read_json(index[#index] or "") or {}).objects or {}) do
		if o.kind == "codemodel" then
			model = read_json(reply .. o.jsonFile)
		end
	end
	if not model then
		return
	end

	local targets, owner = {}, {}
	for _, ref in ipairs(model.configurations[1].targets) do
		local t = read_json(reply .. ref.jsonFile)
		if t then
			targets[#targets + 1] = t
			for _, src in ipairs(t.sources or {}) do
				if real(abs(model.paths.source, src.path)) == path then
					owner[t.id] = true
				end
			end
		end
	end

	local out = {}
	for _, t in ipairs(targets) do
		if t.type == "EXECUTABLE" and t.artifacts then
			local owns = owner[t.id] or false
			for _, d in ipairs(t.dependencies or {}) do
				owns = owns or owner[d.id] or false
			end
			out[#out + 1] = {
				name = t.name,
				owns = owns,
				build = ("cmake --build %s --target %s"):format(q(rel(root, dir)), t.name),
				run = exe(root, abs(model.paths.build, t.artifacts[1].path)),
			}
		end
	end
	return out
end

local function meson(root, path)
	if not vim.uv.fs_stat(root .. "/meson.build") then
		return
	end
	for _, dir in ipairs(build_dirs(root, path)) do
		local targets = read_json(dir .. "/meson-info/intro-targets.json")
		if targets then
			local out = {}
			for _, t in ipairs(targets) do
				if t.type == "executable" then
					local owns = false
					for _, ts in ipairs(t.target_sources or {}) do
						for _, src in ipairs(ts.sources or {}) do
							owns = owns or real(src) == path
						end
					end
					out[#out + 1] = {
						name = t.name,
						owns = owns,
						build = ("meson compile -C %s %s"):format(q(rel(root, dir)), t.name),
						run = exe(root, t.filename[1]),
					}
				end
			end
			return out
		end
	end
end

local HOST_ARCH = ({
	x64 = { "x86_64", "x64", "amd64", "x86" },
	arm64 = { "aarch64", "arm64", "arm" },
})[jit.arch] or {}
local ARCHES = { "x86_64", "x64", "amd64", "x86", "i386", "aarch64", "arm64", "arm", "riscv", "wasm" }

--- a config naming another CPU builds a binary this host cannot run
local function config_score(name)
	name = name:lower()
	local native = vim.iter(HOST_ARCH):any(function(a)
		return name:find(a, 1, true) ~= nil
	end)
	local foreign = not native
		and vim.iter(ARCHES):any(function(a)
			return name:find(a, 1, true) ~= nil
		end)
	local kind = name:find("profil") and 3 or name:find("release") and 2 or name:find("debug") and 0 or 1
	return (foreign and -10 or 0) + kind
end

--- one generated gmake project file: its sources and the binary of its best config for profiling
local function premake_project(mk)
	local dir, cfg, tdir, target, srcs = vim.fs.dirname(mk), nil, {}, {}, {}
	for _, l in ipairs(vim.fn.readfile(mk)) do
		local c = l:match("^ifeq %(%$%(config%),(.-)%)$") or l:match("^else ifeq %(%$%(config%),(.-)%)$")
		if c then
			cfg = c
		elseif cfg and l:match("^TARGETDIR = ") then
			tdir[cfg] = l:match("^TARGETDIR = (.*)$")
		elseif cfg and l:match("^TARGET = ") then
			target[cfg] = (l:match("^TARGET = (.*)$"):gsub("%$%(TARGETDIR%)", function()
				return tdir[cfg] or "."
			end))
		else
			local src = l:match("^%$%(OBJDIR%)/[^:]+:%s+(.+)$")
			if src then
				srcs[real(abs(dir, src))] = true
			end
		end
	end

	local configs = vim.tbl_keys(target)
	table.sort(configs)
	local pick, best = nil, -math.huge
	for _, c in ipairs(configs) do
		if config_score(c) > best then
			pick, best = c, config_score(c)
		end
	end
	if not pick or target[pick]:match("%.a$") or target[pick]:match("%.so[.%d]*$") then
		return
	end
	return {
		name = vim.fn.fnamemodify(mk, ":t:r"),
		dir = dir,
		config = pick,
		target = abs(dir, target[pick]),
		srcs = srcs,
	}
end

local function premake(root, path)
	local script = vim.fs.find("premake5.lua", { path = vim.fs.dirname(path), upward = true })[1]
	if not script or not vim.startswith(script, root .. "/") then
		return
	end
	local file = script == root .. "/premake5.lua" and "" or " --file=" .. q(rel(root, script))

	-- beta8 renamed gmake2 to gmake
	local action
	for _, a in ipairs({ "gmake", "gmake2" }) do
		if sh({ "premake5", "--file=" .. script, a }, { cwd = root }).code == 0 then
			action = a
			break
		end
	end
	if not action then
		return
	end

	local regen = ("premake5%s %s"):format(file, action)
	local makes = vim.fs.find(function(n)
		return n:match("%.make$") ~= nil
	end, { path = vim.fs.dirname(script), limit = math.huge, type = "file" })

	local out = {}
	for _, mk in ipairs(makes) do
		local p = premake_project(mk)
		if p then
			out[#out + 1] = {
				name = p.name,
				owns = p.srcs[path] or false,
				build = ("%s && make -C %s -j$(nproc) config=%s %s"):format(
					regen,
					q(rel(root, p.dir)),
					p.config,
					p.name
				),
				run = exe(root, p.target),
			}
		end
	end
	return out
end

---@return table|false|nil the target, false when the user cancelled
local function detect(root, path, ft)
	local found = ft == "rust" and cargo(root, path) or nil
	found = found or premake(root, path) or meson(root, path) or cmake(root, path) or {}

	local owners = vim.tbl_filter(function(c)
		return c.owns
	end, found)
	local list = #owners > 0 and owners or found
	if #list == 1 then
		return list[1]
	elseif #list > 1 then
		return choose(list, "perf: binary to profile", function(c)
			return c.name .. "  —  " .. c.run
		end) or false
	end
	return { build = vim.uv.fs_stat(root .. "/Makefile") and "make" or "", run = "" }
end

local function configure(root, path, ft, cur)
	local d = cur or detect(root, path, ft)
	if not d then
		return
	end
	local build = input(("perf build (in %s): "):format(vim.fn.fnamemodify(root, ":~")), d.build)
	if not build then
		return
	end
	local run = input("perf run: ", d.run)
	if not run or vim.trim(run) == "" then
		return
	end
	local depth = input("perf tree depth: ", tostring(d.depth or DEPTH))
	if not depth then
		return
	end
	local cfg = {
		build = vim.trim(build),
		run = vim.trim(run),
		pin = not cur or cur.pin ~= false,
		depth = math.max(1, math.min(64, tonumber(depth) or DEPTH)),
	}
	save(root, cfg)
	return cfg
end

--- this user's processes; others' fail the /proc/<pid>/exe readlink
local function processes()
	local me, out = vim.fn.getpid(), {}
	for name in vim.fs.dir("/proc") do
		local pid = tonumber(name)
		local exe = pid and pid ~= me and vim.uv.fs_readlink(("/proc/%d/exe"):format(pid))
		if exe then
			local cmd = table.concat(vim.fn.readfile(("/proc/%d/cmdline"):format(pid), "b"), " ")
			out[#out + 1] = { pid = pid, exe = (exe:gsub(" %(deleted%)$", "")), cmd = vim.trim((cmd:gsub("[%z\n]", " "))) }
		end
	end
	table.sort(out, function(a, b)
		return a.pid > b.pid
	end)
	return out
end

--- the newest process running the configured binary, else the user picks one
local function pick_process(root, cfg)
	local procs = processes()
	local bin = cfg and cfg.run and cfg.run:match("^%s*['\"]?([^%s'\"]+)")
	bin = bin and real(abs(root, bin))
	local same = vim.tbl_filter(function(p)
		return p.exe == bin
	end, procs)
	if #same == 1 then
		return same[1]
	end
	return choose(#same > 0 and same or procs, "perf: process to attach to", function(p)
		return ("%7d  %s"):format(p.pid, p.cmd ~= "" and p.cmd or p.exe)
	end)
end

local probed

--- first event set and call-graph mode this CPU and kernel accept
local function probe()
	if probed then
		return probed
	end
	local tmp = vim.fn.tempname()
	local err = ""
	for _, set in ipairs({ PRECISE, GENERIC }) do
		for _, cg in ipairs({ "lbr", "fp" }) do
			local ev = table.concat(set, ",")
			local res = sh({ "perf", "record", "-q", "-N", "-m", MMAP_PAGES, "-o", tmp, "--call-graph", cg, "-e", ev, "--", "true" })
			if res.code == 0 then
				os.remove(tmp)
				local cpus = vim.uv.fs_stat("/sys/devices/cpu_core/cpus") and vim.fn.readfile("/sys/devices/cpu_core/cpus")[1]
				probed = { events = ev, callgraph = cg, cores = cpus and vim.trim(cpus) or nil }
				return probed
			end
			err = res.stderr or ""
		end
	end
	os.remove(tmp)
	return nil, err
end

local function evkey(name)
	return ALIAS[name:match("^[%w_]+/([^/]+)/") or name:match("^([^:]+)")]
end

---@return table[] samples, table<string, table> frames, integer lost
local function parse(text)
	local samples, frames, cur, lost = {}, {}, nil, 0
	for line in text:gmatch("[^\n]+") do
		local t, period, ev = line:match("^%s*([%d.]+):%s+(%d+)%s+(%S+):")
		local dropped = not t and line:match("PERF_RECORD_LOST.-lost (%d+)")
		if dropped then
			lost = lost + tonumber(dropped)
		elseif t then
			ev = evkey(ev)
			cur = ev and { t = tonumber(t), period = tonumber(period), ev = ev, stack = {} } or nil
			samples[#samples + 1] = cur
		elseif cur then
			local loc = line:match("^%s+%x+%s+%((.*)%)$")
			if loc then
				local dso, off = loc:match("^(.*)%+0x(%x+)$")
				local key = dso and loc or (loc:match("^%[.*%]$") or "[unknown]")
				frames[key] = frames[key] or { dso = dso or key, off = off and tonumber(off, 16) }
				-- LBR call stacks repeat the sampled ip as their first entry
				if cur.stack[#cur.stack] ~= key then
					cur.stack[#cur.stack + 1] = key
				end
			end
		end
	end
	return vim.tbl_filter(function(s)
		return #s.stack > 0
	end, samples), frames, lost
end

--- perf gives file offsets; DWARF and objdump want virtual addresses
local function segments(dso)
	local segs = {}
	local res = sh({ "readelf", "-lW", dso })
	for off, va, size in (res.stdout or ""):gmatch("LOAD%s+0x(%x+)%s+0x(%x+)%s+0x%x+%s+0x(%x+)") do
		segs[#segs + 1] = { off = tonumber(off, 16), va = tonumber(va, 16), size = tonumber(size, 16) }
	end
	return segs
end

local function to_vaddr(segs, off)
	for _, sg in ipairs(segs) do
		if off >= sg.off and off < sg.off + sg.size then
			return off - sg.off + sg.va
		end
	end
	return off
end

--- inline chain per frame, innermost first
local function symbolize(frames)
	local by = {}
	for key, f in pairs(frames) do
		if f.off and vim.startswith(f.dso, "/") then
			by[f.dso] = by[f.dso] or {}
			table.insert(by[f.dso], key)
		end
	end

	local sym = {}
	for dso, keys in pairs(by) do
		local segs = segments(dso)
		local addrs = {}
		for i, k in ipairs(keys) do
			frames[k].va = to_vaddr(segs, frames[k].off)
			addrs[i] = ("0x%x"):format(frames[k].va)
		end
		local res = sh(
			{ "llvm-symbolizer", "--obj=" .. dso, "--inlining", "--output-style=JSON" },
			{ stdin = table.concat(addrs, "\n") .. "\n" }
		)
		local i = 0
		for line in (res.stdout or ""):gmatch("[^\n]+") do
			i = i + 1
			local ok, j = pcall(vim.json.decode, line)
			local key = keys[i]
			if ok and key then
				local chain = {}
				for _, x in ipairs(j.Symbol or {}) do
					local fn = x.FunctionName
					if not fn or fn == "" or fn == "??" then
						fn = vim.fs.basename(dso) .. " (no symbols)"
					end
					chain[#chain + 1] = { fn = fn, file = x.FileName ~= "" and real(x.FileName) or nil, line = x.Line }
				end
				sym[key] = #chain > 0 and chain or nil
			end
		end
	end

	for key, f in pairs(frames) do
		if not sym[key] then
			local fn = f.off and vim.fs.basename(f.dso) .. " (no symbols)" or f.dso
			sym[key] = { { fn = fn } }
		end
	end
	return sym
end

local function add(t, k, v)
	t[k] = (t[k] or 0) + v
end

local function insert(root, names, w)
	root.w = root.w + w
	local node = root
	for _, name in ipairs(names) do
		node.kids[name] = node.kids[name] or { name = name, w = 0, kids = {} }
		node = node.kids[name]
		node.w = node.w + w
	end
end

--- self: in the selection or inlined into it from another file; depth caps both trees
local function aggregate(samples, frames, sym, path, l1, l2, depth)
	local p = {
		total = {},
		self = {},
		incl = {},
		lines = {},
		callers = {},
		callees = {},
		hot = {},
		hotline = {},
		dsos = {},
		times = {},
		count = #samples,
		frames = frames,
		mapped = false,
	}

	for _, smp in ipairs(samples) do
		local ev, w = smp.ev, smp.period
		add(p.total, ev, w)
		p.dsos[ev] = p.dsos[ev] or {}
		add(p.dsos[ev], frames[smp.stack[1]].dso, w)
		p.t0 = math.min(p.t0 or smp.t, smp.t)
		p.t1 = math.max(p.t1 or smp.t, smp.t)

		local flat, hit, leaf = {}, nil, 0
		for i, key in ipairs(smp.stack) do
			for _, f in ipairs(sym[key]) do
				flat[#flat + 1] = f
				if f.file == path then
					p.mapped = true
					if not hit and f.line >= l1 and f.line <= l2 then
						hit = #flat
					end
				end
			end
			if i == 1 then
				leaf = #flat
			end
		end
		p.times[#p.times + 1] = { smp.t, ev, w, hit ~= nil }

		if hit then
			local self = hit <= leaf
			for k = 1, hit - 1 do
				self = self and flat[k].file ~= path
			end

			local ln = flat[hit].line
			p.lines[ln] = p.lines[ln] or { self = {}, incl = {} }
			add(p.lines[ln].incl, ev, w)
			add(p.incl, ev, w)
			if self then
				add(p.lines[ln].self, ev, w)
				add(p.self, ev, w)
				p.hot[ev] = p.hot[ev] or {}
				add(p.hot[ev], smp.stack[1], w)
				p.hotline[smp.stack[1]] = ln
			else
				local names = {}
				for k = hit - 1, math.max(1, hit - depth), -1 do
					names[#names + 1] = flat[k].fn
				end
				if hit - 1 > depth then
					names[depth] = "… › " .. flat[1].fn
				end
				p.callees[ev] = p.callees[ev] or { w = 0, kids = {} }
				insert(p.callees[ev], names, w)
			end

			-- LBR call stacks survive exec, so frames above _start belong to the launching shell
			local outer = #flat
			for k = hit, #flat do
				if flat[k].fn == "_start" then
					outer = k
					break
				end
			end

			local top_k = math.min(outer, hit + depth - 1)
			local names = {}
			for k = top_k, hit, -1 do
				names[#names + 1] = flat[k].fn
			end
			if top_k < outer then
				names[1] = "… › " .. names[1]
			end
			p.callers[ev] = p.callers[ev] or { w = 0, kids = {} }
			insert(p.callers[ev], names, w)
		end
	end
	return p
end

local function top(t, n)
	local out = {}
	for k, v in pairs(t or {}) do
		out[#out + 1] = { k, v }
	end
	table.sort(out, function(a, b)
		return a[2] > b[2]
	end)
	return vim.list_slice(out, 1, n)
end

local function disassemble(p)
	p.asm = {}
	local intel = jit and jit.arch == "x64"
	for _, ev in ipairs(SHOWN) do
		for _, item in ipairs(top(p.hot[ev], 12)) do
			local key = item[1]
			local f = p.frames[key]
			if p.asm[key] == nil and f.va then
				p.asm[key] = ""
				local argv = {
					"objdump",
					"-dwC",
					"--no-show-raw-insn",
					("--start-address=0x%x"):format(f.va),
					("--stop-address=0x%x"):format(f.va + 16),
					f.dso,
				}
				if intel then
					table.insert(argv, 2, "-Mintel")
				end
				local want = ("%x"):format(f.va)
				for line in (sh(argv).stdout or ""):gmatch("[^\n]+") do
					local a, insn = line:match("^%s*(%x+):%s+(.+)$")
					if a == want then
						p.asm[key] = (insn:gsub("%s+", " "))
						break
					end
				end
			end
		end
	end
end

local function bar(v, max, w)
	local n = (max > 0 and v > 0) and math.max(1, math.floor(v / max * w * 8 + 0.5)) or 0
	return ("█"):rep(math.floor(n / 8)) .. (EIGHTHS[n % 8] or "") .. (" "):rep(w - math.ceil(n / 8))
end

--- solid for self time, light shade for the rest of the inclusive time
local function bar2(self, incl, max, w)
	if max <= 0 or incl <= 0 then
		return (" "):rep(w)
	end
	local cells = math.max(1, math.floor(incl / max * w + 0.5))
	local n8 = math.floor(self / max * w * 8 + 0.5)
	if n8 == 0 and self >= incl / 2 then
		n8 = 1
	end
	local full = math.min(math.floor(n8 / 8), cells)
	local part = full < cells and EIGHTHS[n8 % 8] or nil
	local used = full + (part and 1 or 0)
	return ("█"):rep(full) .. (part or "") .. ("░"):rep(cells - used) .. (" "):rep(w - cells)
end

local function spark(vals, max)
	local out = {}
	for i, v in ipairs(vals) do
		local n = (max > 0 and v > 0) and math.max(1, math.floor(v / max * 8 + 0.5)) or 0
		out[i] = SPARK[n + 1]
	end
	return table.concat(out)
end

local function pct(v, t)
	return (v and v > 0 and t and t > 0) and ("%.1f%%"):format(100 * v / t) or "·"
end

local function ratio(a, b)
	return (a and b and b > 0) and ("%.2f"):format(a / b) or "·"
end

--- events per 1000 instructions
local function mpki(a, insns)
	return (insns and insns > 0) and ("%.1f"):format(1000 * (a or 0) / insns) or "·"
end

local function fit(s, w)
	s = s:gsub("\t", " ")
	if vim.fn.strdisplaywidth(s) > w then
		s = vim.fn.strcharpart(s, 0, w - 1) .. "…"
	end
	return s .. (" "):rep(w - vim.fn.strdisplaywidth(s))
end

--- keeps the tail, where the innermost frame of a call path sits
local function fit_left(s, w)
	local n = vim.fn.strchars(s)
	if vim.fn.strdisplaywidth(s) > w then
		s = "…" .. vim.fn.strcharpart(s, n - w + 1)
	end
	return s .. (" "):rep(w - vim.fn.strdisplaywidth(s))
end

local function highlights()
	for name, link in pairs({
		PerfHot = "DiagnosticError",
		PerfWarm = "DiagnosticWarn",
		PerfCool = "Comment",
		PerfBar = "Special",
		PerfHead = "Title",
	}) do
		vim.api.nvim_set_hl(0, name, { link = link, default = true })
	end
end

local SMALL_W, SMALL_H = 64, 4

local function retitle(s, tail)
	s.tail = tail
	local title = ("perf  %s %d-%d  ·  %s"):format(vim.fs.basename(s.path), s.l1, s.l2, tail)
	if s.small then
		ui.retitle(s.win, title, SMALL_W, SMALL_H)
	else
		ui.retitle(s.win, title)
	end
end

--- ppid, user+system CPU ticks (threads included) and start time of one process
local function stat(pid)
	local fh = io.open(("/proc/%d/stat"):format(pid))
	if not fh then
		return
	end
	local line = fh:read("*l")
	fh:close()
	-- comm can hold spaces and parens, so fields are counted after its last ")"
	local f = vim.split((line or ""):match("%) (.*)$") or "", " ")
	if #f < 20 then
		return
	end
	return tonumber(f[2]), tonumber(f[12]) + tonumber(f[13]), f[20]
end

---@return integer[] pids, table<integer, integer> ticks
local function descendants(root)
	local kids, ticks = {}, {}
	for name in vim.fs.dir("/proc") do
		local pid = tonumber(name)
		local ppid, t = nil, nil
		if pid then
			ppid, t = stat(pid)
		end
		if ppid then
			kids[ppid] = kids[ppid] or {}
			table.insert(kids[ppid], pid)
			ticks[pid] = t
		end
	end
	local out, queue = {}, vim.list_extend({}, kids[root] or {})
	while #queue > 0 do
		local pid = table.remove(queue)
		out[#out + 1] = pid
		vim.list_extend(queue, kids[pid] or {})
	end
	return out, ticks
end

local function descendant_ticks(root)
	local pids, ticks = descendants(root)
	local sum = 0
	for _, pid in ipairs(pids) do
		sum = sum + ticks[pid]
	end
	return sum
end

--- SIGINT lets perf finish its file; a launched workload that outlives perf is then killed
local function abort(s, leaving)
	if not s.proc then
		return
	end
	local workload = {}
	if not s.pid and s.st and s.st.root then
		for _, pid in ipairs((descendants(s.st.root))) do
			workload[pid] = select(3, stat(pid))
		end
	end
	s.proc:kill("sigint")
	-- the start time check keeps a recycled pid from being killed
	local function kill_rest()
		for pid, start in pairs(workload) do
			if select(3, stat(pid)) == start then
				pcall(vim.uv.kill, pid, "sigkill")
			end
		end
	end
	if leaving then
		kill_rest()
	elseif next(workload) then
		vim.defer_fn(kill_rest, 2000)
	end
end

-- /proc reports CPU time in USER_HZ, which Linux fixes at 100 on every architecture
local USER_HZ = 100
-- perf record's default sampling frequency per event, in samples per CPU-second
local SAMPLE_HZ = 4000

local function show_status(s)
	local st = s.st
	if not (s.small and st and vim.api.nvim_buf_is_valid(s.buf)) then
		return
	end
	local lines = { ("%s  %.1f s"):format(st.phase, (vim.uv.hrtime() - st.t0) / 1e9) }
	if st.data then
		-- only cycles and instructions fire often enough to reach the target rate
		lines[#lines + 1] = ("~%d samples so far (estimated from target CPU time)"):format(st.cpu_s * SAMPLE_HZ * 2)
		local peak = 100
		for _, v in ipairs(st.cpu) do
			peak = math.max(peak, v)
		end
		lines[#lines + 1] = ("target CPU %s %4.0f%%"):format(spark(st.cpu, peak), st.cpu[#st.cpu] or 0)
		if st.tui then
			lines[#lines + 1] = "looks like a TUI with no terminal — use <leader>P to attach"
		end
	end
	ui.render(s.buf, lines)
end

local function tick(s)
	local st = s.st
	if not st then
		return
	end
	if st.data then
		local ticks
		if s.pid then
			ticks = select(2, stat(s.pid))
		elseif st.root then
			ticks = descendant_ticks(st.root)
		end
		local now = vim.uv.hrtime()
		if ticks and st.last then
			local used = math.max(0, ticks - st.last.ticks) / USER_HZ
			st.cpu_s = st.cpu_s + used
			local pct = used / ((now - st.last.t) / 1e9) * 100
			table.insert(st.cpu, math.max(0, pct))
			if #st.cpu > 40 then
				table.remove(st.cpu, 1)
			end
		end
		st.last = ticks and { ticks = ticks, t = now } or nil
	end
	show_status(s)
end

local function stop_status(s)
	if s.timer then
		s.timer:stop()
		s.timer:close()
		s.timer = nil
	end
	s.st = nil
	s.small = false
end

local function start_status(s)
	stop_status(s)
	s.small = true
	s.st = { phase = "starting…", t0 = vim.uv.hrtime(), cpu = {}, cpu_s = 0 }
	s.timer = vim.uv.new_timer()
	s.timer:start(0, 250, vim.schedule_wrap(function()
		tick(s)
	end))
end

local function phase(s, name, keys)
	if s.st then
		s.st.phase = name
	end
	retitle(s, name .. (keys or ""))
	show_status(s)
end

local function inline(s)
	if not vim.api.nvim_buf_is_valid(s.src_buf) then
		return
	end
	vim.api.nvim_buf_clear_namespace(s.src_buf, ns, 0, -1)
	local p, ev = s.prof, s.ev
	local tot = p.total[ev] or 0
	local max = 0
	for _, d in pairs(p.lines) do
		max = math.max(max, d.incl[ev] or 0)
	end
	for ln, d in pairs(p.lines) do
		local self, incl = d.self[ev] or 0, d.incl[ev] or 0
		if tot > 0 and incl > 0 then
			local share = incl / tot
			local hl = share >= 0.10 and "PerfHot" or share >= 0.02 and "PerfWarm" or "PerfCool"
			local text = ("%s %5.1f%%"):format(bar2(self, incl, max, 8), 100 * share)
			if incl - self > 0.005 * tot then
				text = text .. ("  (self %.1f%%)"):format(100 * self / tot)
			end
			local code = vim.api.nvim_buf_get_lines(s.src_buf, ln - 1, ln, false)[1] or ""
			local lead = code:match("^%s*")
			local _, tabs = lead:gsub("\t", "")
			local indent = #lead - tabs + tabs * vim.bo[s.src_buf].tabstop
			pcall(vim.api.nvim_buf_set_extmark, s.src_buf, ns, ln - 1, 0, {
				virt_lines = { { { (" "):rep(indent), "" }, { text, hl } } },
				virt_lines_above = true,
			})
		end
	end
end

local MIN_SAMPLES = 100

local function unmapped(s, p)
	local out = { ("no sample maps to %s"):format(vim.fs.basename(s.path)) }
	if p.exit ~= 0 and not p.stopped then
		out[#out + 1] = ("run failed: exit %d"):format(p.exit)
		for _, l in ipairs(vim.list_slice(vim.split(vim.trim(p.stderr), "\n"), 1, 5)) do
			out[#out + 1] = "  " .. l
		end
	elseif p.count < MIN_SAMPLES then
		out[#out + 1] = ("only %d samples in %.0f ms; %s"):format(
			p.count,
			p.wall * 1000,
			s.pid and "process mostly idle" or "run too short"
		)
	else
		out[#out + 1] = "debug info missing, or the run command never reaches this file"
	end
	vim.list_extend(out, { "", "where cycles went:" })
	for _, item in ipairs(top(p.dsos.cycles, 6)) do
		out[#out + 1] = ("  %6s  %s"):format(pct(item[2], p.total.cycles), item[1])
	end
	return out
end

local function draw(buf)
	local s = state[buf]
	local p, ev = s.prof, s.ev
	highlights()
	if not p.mapped then
		ui.render(buf, unmapped(s, p))
		s.rows = {}
		return retitle(s, s.pid and KEYS_ATTACHED or KEYS)
	end

	local W = ui.geometry().width
	local tot = p.total[ev] or 0
	local out, rows = {}, {}
	local function put(line, src)
		out[#out + 1] = line
		rows[#out] = src
	end

	put(("%s  %s incl · %s self   %s"):format(LABEL[ev], pct(p.incl[ev], tot), pct(p.self[ev], tot), "(of all samples)"))
	put(("IPC %s · LLC %s/1k insn · branch miss %s/1k insn   (selection self)"):format(
		ratio(p.self.insns, p.self.cycles),
		mpki(p.self.llc, p.self.insns),
		mpki(p.self.br, p.self.insns)
	))
	put(("%d samples · %.2f s · %s · %s · %s"):format(
		p.count,
		(p.t1 or 0) - (p.t0 or 0),
		s.pid and ("attached " .. s.pid) or p.cores and ("pinned " .. p.cores) or "unpinned",
		p.callgraph,
		(p.stopped and "stopped" or ("exit " .. p.exit)) .. (p.lost > 0 and (" · %d lost"):format(p.lost) or "")
	))
	if p.exit ~= 0 and not p.stopped and p.stderr ~= "" then
		for _, l in ipairs(vim.list_slice(vim.split(vim.trim(p.stderr), "\n"), 1, 3)) do
			put("  " .. l)
		end
	end

	local CODE = math.max(12, W - 62)
	put("")
	put(("Lines · %s · █ self  ░ in callees"):format(LABEL[ev]))
	put(("  %5s  %s  %-12s %6s %6s  %5s %6s %6s"):format("line", fit("", CODE), "", "self", "incl", "IPC", "LLC/k", "br/k"))
	local nums = vim.tbl_filter(function(ln)
		return (p.lines[ln].incl[ev] or 0) > 0
	end, vim.tbl_keys(p.lines))
	table.sort(nums)
	local max = 0
	for _, ln in ipairs(nums) do
		max = math.max(max, p.lines[ln].incl[ev] or 0)
	end
	for _, ln in ipairs(nums) do
		local d = p.lines[ln]
		put(
			("  %5d  %s  %s %6s %6s  %5s %6s %6s"):format(
				ln,
				fit(vim.trim(s.src[ln] or ""), CODE),
				bar2(d.self[ev] or 0, d.incl[ev] or 0, max, 12),
				pct(d.self[ev], tot),
				pct(d.incl[ev], tot),
				ratio(d.self.insns, d.self.cycles),
				mpki(d.self.llc, d.self.insns),
				mpki(d.self.br, d.self.insns)
			),
			ln
		)
	end
	if #nums == 0 then
		put("  none")
	end

	local n = math.max(10, W - 8)
	local span = math.max((p.t1 or 0) - (p.t0 or 0), 1e-9)
	local all, sel = {}, {}
	for i = 1, n do
		all[i], sel[i] = 0, 0
	end
	for _, x in ipairs(p.times) do
		if x[2] == ev then
			local b = math.min(n, math.floor((x[1] - p.t0) / span * n) + 1)
			all[b] = all[b] + x[3]
			if x[4] then
				sel[b] = sel[b] + x[3]
			end
		end
	end
	local peak = math.max(unpack(all))
	put("")
	put(("Timeline · %s over %.2f s"):format(LABEL[ev], span))
	put("  all " .. spark(all, peak))
	put("  sel " .. spark(sel, peak))

	local NAME = W - 22
	local function tree(root)
		if not root then
			return put("  none")
		end
		local budget = 30
		local function walk(node, prefix, first)
			local kids = vim.tbl_filter(function(k)
				return k.w >= 0.01 * root.w
			end, vim.tbl_values(node.kids))
			table.sort(kids, function(a, b)
				return a.w > b.w
			end)
			for i, kid in ipairs(kids) do
				if budget == 0 then
					return
				end
				budget = budget - 1
				local last = i == #kids
				local lead = first and "" or prefix .. (last and "└ " or "├ ")
				put(("  %s %s %6s"):format(fit_left(lead .. kid.name, NAME), bar(kid.w, root.w, 10), pct(kid.w, tot)))
				walk(kid, first and "" or prefix .. (last and "  " or "│ "), false)
			end
		end
		walk(root, "", true)
	end

	put("")
	put(("Callers · %s reaching the selection"):format(LABEL[ev]))
	tree(p.callers[ev])

	put("")
	put(("Callees · %s inside calls made from the selection"):format(LABEL[ev]))
	tree(p.callees[ev])

	put("")
	put(("Hot instructions · self %s"):format(LABEL[ev]))
	local hot = top(p.hot[ev], 12)
	for _, item in ipairs(hot) do
		local key = item[1]
		put(
			("  %8x  %5d  %s %6s  %s"):format(
				p.frames[key].va or 0,
				p.hotline[key],
				bar(item[2], hot[1][2], 10),
				pct(item[2], tot),
				p.asm[key] or ""
			),
			p.hotline[key]
		)
	end
	if #hot == 0 then
		put("  none")
	end

	ui.render(buf, out)
	s.rows = rows
	inline(s)
	retitle(s, LABEL[ev] .. "  ·  " .. (s.pid and KEYS_ATTACHED or KEYS))
end

local function run(buf)
	local s = state[buf]
	if not s then
		return
	end
	abort(s)
	s.gen = (s.gen or 0) + 1
	local gen = s.gen
	local function live()
		return vim.api.nvim_buf_is_valid(buf) and state[buf] == s and s.gen == gen
	end
	local function fail(title, text)
		if live() then
			stop_status(s)
			ui.render(buf, vim.split(vim.trim(text ~= "" and text or title), "\n"))
			retitle(s, title .. "  ·  [R] rerun  [c] config  [q] close")
		end
	end

	if recording and recording ~= s and state[recording.buf] == recording then
		ui.render(buf, {
			("recording already running: %s %d-%d"):format(vim.fs.basename(recording.path), recording.l1, recording.l2),
			"stop it with [x] in its float, then [R] here",
		})
		return retitle(s, "busy  ·  [R] rerun  [q] close")
	end

	start_status(s)
	spawn(function()
		local cfg = s.cfg
		s.stopped = false
		if not s.pid and cfg.build ~= "" then
			phase(s, "building…")
			local res = sh({ "sh", "-c", cfg.build }, { cwd = s.root })
			if not live() then
				return
			end
			if res.code ~= 0 then
				return fail("build failed", (res.stdout or "") .. (res.stderr or ""))
			end
		end

		local pmu, err = probe()
		if not live() then
			return
		end
		if not pmu then
			return fail("perf record refused every event set", err)
		end

		local data = vim.fn.tempname() .. ".data"
		local cores = not s.pid and cfg.pin and pmu.cores or nil
		local argv = cores and { "taskset", "-c", cores } or {}
		vim.list_extend(argv, { "perf", "record", "-q", "-N", "-m", MMAP_PAGES, "-o", data, "--call-graph", pmu.callgraph })
		vim.list_extend(argv, { "-e", pmu.events })
		s.st.data, s.st.t0 = data, vim.uv.hrtime()
		if s.pid then
			vim.list_extend(argv, { "-p", tostring(s.pid) })
			phase(s, ("attached to %d"):format(s.pid), "  ·  [x] stop")
		else
			vim.list_extend(argv, { "--", "sh", "-c", cfg.run })
			phase(s, "recording", "  ·  [x] stop")
		end
		local st = s.st
		-- a terminal UI writes escape sequences; with no terminal it never sees its user
		local function sniff(_, chunk)
			if chunk and not st.tui and chunk:find("\27[", 1, true) then
				st.tui = true
			end
		end
		local started = vim.uv.hrtime()
		recording = s
		local rec = sh(argv, { cwd = s.root, stdout = sniff }, function(obj)
			s.proc = obj
			st.root = obj.pid
		end)
		local wall = (vim.uv.hrtime() - started) / 1e9
		-- a rerun may already own both by the time this perf exits
		if s.gen == gen then
			s.proc = nil
			if recording == s then
				recording = nil
			end
		end
		st.data = nil
		if not live() then
			return os.remove(data)
		end
		-- an attached perf only ends by SIGINT (130) or the target exiting (143)
		local attach_failed = s.pid and rec.code ~= 0 and rec.code ~= 130 and rec.code ~= 143
		local written = vim.uv.fs_stat(data)
		if not written or written.size == 0 or attach_failed then
			os.remove(data)
			return fail(("perf record failed: exit %d"):format(rec.code), rec.stderr or "")
		end

		phase(s, "reading samples…")
		local scr = sh({
			"perf",
			"script",
			"-i",
			data,
			"-F",
			"time,event,period,ip,dso,dsoff",
			"--no-inline",
			"--show-lost-events",
		})
		os.remove(data)
		if not live() then
			return
		end
		if scr.code ~= 0 then
			return fail("perf script failed", scr.stderr or "")
		end

		phase(s, "symbolizing…")
		local samples, frames, lost = parse(scr.stdout or "")
		local sym = symbolize(frames)
		if not live() then
			return
		end

		local p = aggregate(samples, frames, sym, s.path, s.l1, s.l2, cfg.depth or DEPTH)
		p.exit, p.stderr, p.cores, p.callgraph, p.wall = rec.code, rec.stderr or "", cores, pmu.callgraph, wall
		p.stopped = s.stopped or (s.pid ~= nil)
		p.lost = lost
		phase(s, "disassembling…")
		disassemble(p)
		if not live() then
			return
		end
		s.prof = p
		stop_status(s)
		draw(buf)
	end)
end

local function cycle_event(buf)
	local s = state[buf]
	if not (s and s.prof) or s.st then
		return
	end
	local i = 1
	for k, e in ipairs(SHOWN) do
		if e == s.ev then
			i = k
		end
	end
	for step = 1, #SHOWN do
		local e = SHOWN[(i + step - 1) % #SHOWN + 1]
		if (s.prof.total[e] or 0) > 0 then
			s.ev = e
			break
		end
	end
	draw(buf)
end

---@param attach boolean? profile a running process instead of building and launching
function M.show(l1, l2, attach)
	local src_buf = vim.api.nvim_get_current_buf()
	local ft = vim.bo[src_buf].filetype
	if ft ~= "c" and ft ~= "cpp" and ft ~= "rust" then
		return warn("no backend for filetype '" .. ft .. "'")
	end
	local name = vim.api.nvim_buf_get_name(src_buf)
	if name == "" or not vim.uv.fs_stat(name) then
		return warn("buffer has no file on disk")
	end
	for _, tool in ipairs({ "perf", "llvm-symbolizer", "readelf", "objdump" }) do
		if vim.fn.executable(tool) == 0 then
			return warn(tool .. " not found")
		end
	end
	if vim.bo[src_buf].modified then
		warn("buffer modified — building the file on disk")
	end

	local path = real(name)
	local root = project_root(path)
	local src_win = vim.api.nvim_get_current_win()
	local src = vim.api.nvim_buf_get_lines(src_buf, 0, -1, false)

	spawn(function()
		local cfg, proc = load()[root], nil
		if attach then
			cfg = cfg or { build = "", run = "", pin = false }
			proc = pick_process(root, cfg)
			if not proc then
				return
			end
		elseif not (cfg and cfg.run) then
			cfg = configure(root, path, ft)
			if not cfg then
				return
			end
		end

		local buf = vim.api.nvim_create_buf(false, true)
		local win = vim.api.nvim_open_win(buf, true, ui.geometry(SMALL_W, SMALL_H))
		vim.bo[buf].bufhidden = "wipe"
		vim.wo[win].wrap = false
		vim.wo[win].cursorline = true
		vim.fn.matchadd("PerfBar", "[▏▎▍▌▋▊▉█▁▂▃▄▅▆▇░]\\+", 10, -1, { window = win })
		vim.fn.matchadd("PerfHead", "^\\S.*", 10, -1, { window = win })

		state[buf] = {
			path = path,
			root = root,
			ft = ft,
			l1 = l1,
			l2 = l2,
			cfg = cfg,
			win = win,
			src = src,
			src_buf = src_buf,
			src_win = src_win,
			ev = "cycles",
			pid = proc and proc.pid,
			buf = buf,
		}
		local s = state[buf]

		local map = function(lhs, fn)
			vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true, silent = true })
		end
		local close = function()
			if vim.api.nvim_win_is_valid(win) then
				vim.api.nvim_win_close(win, true)
			end
		end
		map("q", close)
		map("<Esc>", close)
		map("R", function()
			run(buf)
		end)
		map("e", function()
			cycle_event(buf)
		end)
		map("x", function()
			if s.proc then
				s.stopped = true
				abort(s)
			end
		end)
		map("p", function()
			if s.pid then
				return
			end
			cfg.pin = not cfg.pin
			save(root, cfg)
			run(buf)
		end)
		map("c", function()
			spawn(function()
				if s.pid then
					local new = pick_process(root, {})
					if new and state[buf] == s then
						s.pid = new.pid
						run(buf)
					end
					return
				end
				local new = configure(root, path, ft, cfg)
				if new and state[buf] == s then
					cfg = new
					s.cfg = new
					run(buf)
				end
			end)
		end)
		map("<CR>", function()
			local ln = s.rows and s.rows[vim.fn.line(".")]
			if ln and vim.api.nvim_win_is_valid(src_win) then
				close()
				vim.api.nvim_set_current_win(src_win)
				vim.api.nvim_win_set_cursor(src_win, { ln, 0 })
			end
		end)

		vim.api.nvim_create_autocmd("VimResized", {
			buffer = buf,
			callback = function()
				if state[buf] and s.tail then
					retitle(s, s.tail)
				end
			end,
		})
		vim.api.nvim_create_autocmd("BufWipeout", {
			buffer = buf,
			callback = function()
				abort(s)
				stop_status(s)
				state[buf] = nil
			end,
		})

		run(buf)
	end)
end

--- Line range of the function enclosing the cursor
local function enclosing_fn()
	local ok, node = pcall(vim.treesitter.get_node)
	if not ok or not node then
		return nil
	end
	while node do
		local t = node:type()
		if t:match("function") or t:match("method") then
			local sr, _, er = node:range()
			return sr + 1, er + 1
		end
		node = node:parent()
	end
end

function M.setup()
	vim.api.nvim_create_autocmd("VimLeavePre", {
		group = vim.api.nvim_create_augroup("user-perf", { clear = true }),
		callback = function()
			for _, s in pairs(state) do
				abort(s, true)
			end
		end,
	})

	vim.api.nvim_create_user_command("Perf", function(o)
		M.show(o.line1, o.line2)
	end, { range = true, desc = "Profile the selected lines" })

	vim.api.nvim_create_user_command("PerfAttach", function(o)
		M.show(o.line1, o.line2, true)
	end, { range = true, desc = "Profile the selected lines in a running process" })

	vim.api.nvim_create_user_command("PerfConfig", function()
		local name = vim.api.nvim_buf_get_name(0)
		if name == "" then
			return warn("buffer has no file on disk")
		end
		local path = real(name)
		local root = project_root(path)
		local ft = vim.bo.filetype
		spawn(function()
			configure(root, path, ft, load()[root])
		end)
	end, { desc = "Edit the build and run commands for this project" })

	vim.api.nvim_create_user_command("PerfClear", function()
		vim.api.nvim_buf_clear_namespace(0, ns, 0, -1)
	end, { desc = "Remove profile heat from this buffer" })

	vim.keymap.set("x", "<leader>p", ":Perf<CR>", { silent = true, desc = "[P]rofile selection" })
	vim.keymap.set("n", "<leader>p", function()
		local l1, l2 = enclosing_fn()
		M.show(l1 or vim.fn.line("."), l2 or vim.fn.line("."))
	end, { desc = "[P]rofile the function under the cursor" })

	vim.keymap.set("x", "<leader>P", ":PerfAttach<CR>", { silent = true, desc = "[P]rofile selection in a running process" })
	vim.keymap.set("n", "<leader>P", function()
		local l1, l2 = enclosing_fn()
		M.show(l1 or vim.fn.line("."), l2 or vim.fn.line("."), true)
	end, { desc = "[P]rofile the function under the cursor in a running process" })
end

return M
