local debug = require('debug')
local package = require('package')
-- TODO(later): re-enable Zomboid stubs when running inside the game runtime.
-- require('util.zomboid_stubs')

-- Explainer: Collect canonical search paths for any vendored libraries we keep under external/.
local LIBRARY_PATHS = {
  'external/lua-reactivex/?.lua',
  'external/lua-reactivex/?/init.lua',
  'external/StarlitLibrary/Contents/mods/StarlitLibrary/42/media/lua/shared/?.lua',
}

local function normalize(path)
  if path:sub(1, 1) == '/' then
    return path
  end

  local pwd = assert(os.getenv('PWD'), 'PWD environment variable is missing')
  return pwd .. '/' .. path
end

local function get_repo_root()
  local source = debug.getinfo(1, 'S').source
  if source:sub(1, 1) == '@' then
    source = source:sub(2)
  end

  local script_dir = source:match('(.*/)') or './'
  return normalize(script_dir)
end

local repo_root = get_repo_root()

-- Explainer: Append the resolved external library paths exactly once to avoid duplicate entries.
local function extend_package_path()
  local extra_paths = {}

  for _, relative in ipairs(LIBRARY_PATHS) do
    table.insert(extra_paths, repo_root .. relative)
  end

  package.path = table.concat({ package.path, table.concat(extra_paths, ';') }, ';')
end

extend_package_path()

local Bootstrap = {}

-- Explainer: Expose the resolved repo root and raw library list for debugging or tooling.
Bootstrap.repoRoot = repo_root
Bootstrap.libraryPaths = LIBRARY_PATHS

return Bootstrap
