local ok_debug, debug = pcall(require, "debug")
local ok_package, package = pcall(function()
	return package
end)
-- If the host does not expose debug/package or getinfo, bail out gracefully (e.g., PZ runtime).
if not (ok_debug and ok_package) or type(debug) ~= "table" or type(debug.getinfo) ~= "function" then
	return {
		repoRoot = nil,
		libraryPaths = {},
	}
end
-- TODO(later): re-enable Zomboid stubs when running inside the game runtime.
-- require("LQR/util/zomboid_stubs")

-- Explainer: Collect canonical search paths for project modules and vendored libraries.
local BASE_PATHS = {
	"?.lua",
	"LQR/?.lua",
}

local LIBRARY_PATHS = {
	-- Preferred: standalone lua-reactivex submodule (sibling to LQR).
	"../lua-reactivex/?.lua",
	-- Fallback: bundled submodule inside this repo.
	"reactivex/?.lua",
}

local function normalize(path, root)
	if path:sub(1, 1) == "/" then
		return path
	end
	return root .. path
end

local function ensure_trailing_slash(path)
	if path:sub(-1) ~= "/" then
		return path .. "/"
	end
	return path
end

local function parent_dir(path)
	local trimmed = path:gsub("/+$", "")
	return trimmed:match("(.+)/[^/]+$") or trimmed
end

local function get_repo_root()
	local info = debug.getinfo(1, "S") or {}
	local source = info.source or ""

	-- If debug info is missing or not a file, fall back to current directory.
	if source:sub(1, 1) ~= "@" then
		source = "./bootstrap.lua"
	else
		source = source:sub(2)
	end

	local script_dir = source:match("(.*/)") or "./"
	local normalized = ensure_trailing_slash(normalize(script_dir, ""))
	return ensure_trailing_slash(parent_dir(normalized))
end

local repo_root = get_repo_root()

-- Explainer: Append the resolved external library paths exactly once to avoid duplicate entries.
local function extend_package_path()
	local extra_paths = {}

	for _, relative in ipairs(BASE_PATHS) do
		table.insert(extra_paths, repo_root .. relative)
	end

	for _, relative in ipairs(LIBRARY_PATHS) do
		table.insert(extra_paths, repo_root .. relative)
	end

	package.path = table.concat({ table.concat(extra_paths, ";"), package.path }, ";")
end

-- Project Zomboid disallows tampering with package.path, so guard the path
-- extension behind a check for writeability while relying on a searcher
-- fallback to load vendored dependencies.
local function safe_extend_package_path()
	local ok = pcall(function()
		local original = package.path
		package.path = original -- test write access
	end)
	if ok then
		extend_package_path()
	end
end

local function add_searcher(prefix, base_dir)
	-- Prefix-aware loader that bypasses package.path by resolving directly
	-- from the repo root (works in PZ where package.path is locked down).
	local function loader(module_name)
		if module_name ~= prefix and not module_name:match("^" .. prefix .. "[%./]") then
			return nil
		end

		local suffix = module_name:gsub("^" .. prefix .. "[%./]?", "")
		local path
		if suffix == "" then
			path = base_dir .. "reactivex/reactivex.lua"
		else
			path = base_dir .. "reactivex/" .. (suffix:gsub("%.", "/") .. ".lua")
		end

		local chunk, err = loadfile(path)
		if chunk then
			return chunk
		end

		return ("\n\tno file '%s' (%s)"):format(path, err or "loadfile failed")
	end

	if type(package.searchers) == "table" then
		table.insert(package.searchers, 1, loader)
	end
end

safe_extend_package_path()
-- Prefer sibling checkout; fallback to bundled submodule.
add_searcher("reactivex", repo_root .. "../lua-reactivex/")
add_searcher("reactivex", repo_root .. "reactivex/")

-- Preload operators aggregator from sibling if present, otherwise bundled copy,
-- to avoid init.lua recursion when hosts resolve that path first.
do
	local candidates = {
		repo_root .. "../lua-reactivex/operators.lua",
		repo_root .. "reactivex/operators.lua",
	}

	for _, op_path in ipairs(candidates) do
		local chunk = loadfile(op_path)
		if chunk then
			local function loader()
				package.loaded["reactivex/operators"] = true
				package.loaded["reactivex.operators"] = true
				return chunk()
			end
			package.preload["reactivex/operators"] = loader
			package.preload["reactivex.operators"] = loader
			break
		end
	end
end

local Bootstrap = {}

-- Explainer: Expose the resolved repo root and raw library list for debugging or tooling.
Bootstrap.repoRoot = repo_root
Bootstrap.libraryPaths = LIBRARY_PATHS

return Bootstrap
