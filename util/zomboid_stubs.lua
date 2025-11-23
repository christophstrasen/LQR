---Explainer: Minimal shims for Project Zomboid-specific Lua helpers so experiments can run outside the game.
local ZomboidStubs = {}

function ZomboidStubs.install()
	-- Implementation Status: Expand with additional helpers as experiments require them.
	if type(table.newarray) ~= "function" then
		table.newarray = function()
			return {}
		end
	end
end

ZomboidStubs.install()

return ZomboidStubs
