require("bootstrap")
local rx = require("reactivex")
local LuaEvent = require("Starlit.LuaEvent")
local io = require("io")

---@type LuaEvent<any>
local testEvent = LuaEvent.new()

local logObservable = rx.Observable.fromLuaEvent(testEvent):map(function(...)
	return {
		timestamp = os.clock(),
		payload = { ... },
	}
end)

local subscription = logObservable:subscribe(function(entry)
	print(("Event @ %.3f seconds | args: %s"):format(entry.timestamp, table.concat(entry.payload, ", ")))
end, function(err)
	io.stderr:write(("LuaEvent error: %s\n"):format(err))
end, function()
	print("LuaEvent stream completed")
end)

-- Explainer: simulate a couple LuaEvent triggers to show the adapter in action.
---@diagnostic disable-next-line: param-type-mismatch
testEvent:trigger("first", "payload")
---@diagnostic disable-next-line: param-type-mismatch
testEvent:trigger("second", "payload", 42)

subscription:unsubscribe()
