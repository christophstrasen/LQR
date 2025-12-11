local debug = require("debug")
local package = require("package")
-- TODO(later): re-enable Zomboid stubs when running inside the game runtime.
-- require("LQR.util.zomboid_stubs')

-- Explainer: Collect canonical search paths for project modules and vendored libraries.
local BASE_PATHS = {
	"?.lua",
	"?/init.lua",
	"LQR/?.lua",
	"LQR/?/init.lua",
}

local LIBRARY_PATHS = {
	-- Preferred: root-level lua-reactivex checkout (e.g., submodule at ./reactivex).
	"reactivex/?.lua",
	"reactivex/?/init.lua",
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

extend_package_path()

local Bootstrap = {}

-- Explainer: Expose the resolved repo root and raw library list for debugging or tooling.
Bootstrap.repoRoot = repo_root
Bootstrap.libraryPaths = LIBRARY_PATHS

return Bootstrap
