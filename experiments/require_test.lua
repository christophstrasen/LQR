require("bootstrap") -- Explainer: ensure shared libs (lua-reactivex, Starlit, etc.) are on package.path.
local io = require("io")
local rx = require("reactivex")

local subscription = rx.Observable
	.fromTable({ "Hello", "from", "lua-reactivex!" })
	:map(function(word)
		return word:upper()
	end)
	:reduce(function(acc, word)
		return acc .. " " .. word
	end)
	:subscribe(function(result)
		print(("Result: %s"):format(result))
	end, function(err)
		io.stderr:write(("Error: %s\n"):format(err))
	end, function()
		print("Stream complete")
	end)

-- Clean up just to show subscription management works.
subscription:unsubscribe()
