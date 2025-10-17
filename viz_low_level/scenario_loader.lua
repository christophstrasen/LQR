local scenarioName = os.getenv("VIZ_SCENARIO") or "left_join"

local function loadScenario(name)
	local modulePath = ("viz_low_level.scenarios.%s.scenario"):format(name)
	local ok, scenario = pcall(require, modulePath)
	if not ok then
		error(("Failed to load scenario '%s' via module '%s': %s"):format(name, modulePath, scenario))
	end
	return scenario, modulePath
end

local scenario, modulePath = loadScenario(scenarioName)

local loader = {
	name = scenarioName,
	module = scenario,
	modulePath = modulePath,
	data = scenario.data,
}

function loader.buildRecipe(observables)
	return scenario.buildRecipe(observables)
end

local cachedRecipe = nil

function loader.getRecipe(observables)
	if not cachedRecipe then
		assert(observables, "observables table required to build scenario recipe")
		cachedRecipe = loader.buildRecipe(observables)
	end
	return cachedRecipe
end

return loader
