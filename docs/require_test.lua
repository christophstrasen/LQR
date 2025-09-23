local debug = require('debug')
local package = require('package')
local io = require('io')

-- Simple example that shows how to bring the lua-reactivex sources that live
-- alongside this workspace into package.path and require them.
local info = debug.getinfo(1, 'S')
local script_dir = info.source:sub(2):match('(.*/)') or './'

local function ensure_absolute(path)
  if path:sub(1, 1) == '/' then
    return path
  end

  local pwd = assert(os.getenv('PWD'), 'PWD environment variable is missing')
  return pwd .. '/' .. path
end

script_dir = ensure_absolute(script_dir)

local lua_reactivex_root = os.getenv('LUA_REACTIVEX_DIR')
if not lua_reactivex_root then
  lua_reactivex_root = script_dir .. '../../lua-reactivex'
end

-- Add the sibling lua-reactivex tree to Lua's module search path.
package.path = table.concat({
  package.path,
  lua_reactivex_root .. '/?.lua',
  lua_reactivex_root .. '/?/init.lua',
}, ';')

local rx = require('reactivex')

local subscription = rx.Observable.fromTable({ 'Hello', 'from', 'lua-reactivex!' })
  :map(function(word) return word:upper() end)
  :reduce(function(acc, word) return acc .. ' ' .. word end)
  :subscribe(function(result)
    print(('Result: %s'):format(result))
  end, function(err)
    io.stderr:write(('Error: %s\n'):format(err))
  end, function()
    print('Stream complete')
  end)

-- Clean up just to show subscription management works.
subscription:unsubscribe()
