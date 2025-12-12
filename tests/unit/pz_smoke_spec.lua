-- Runs the CLI smoke test under busted to mirror PZ's loader constraints.
-- This does not require Project Zomboid; it simply calls our helper script,
-- which guards against missing debug/package and validates requires.

local function exit_ok(status, kind, code)
	-- Lua 5.1: os.execute returns status code (number)
	if type(status) == "number" then
		return status == 0
	end
	-- Lua 5.2+: os.execute returns success (boolean), "exit"/"signal", code
	if status == true then
		return true
	end
	if status == "exit" then
		return code == 0
	end
	return false
end

describe("PZ-style smoke", function()
	it("loads core modules without debug/package", function()
		local cmd = 'lua scripts/pz_smoke.lua reactivex LQR'
		local status, kind, code = os.execute(cmd)
		assert.is_true(exit_ok(status, kind, code), ("smoke script failed: status=%s kind=%s code=%s"):format(
			tostring(status),
			tostring(kind),
			tostring(code)
		))
	end)
end)
