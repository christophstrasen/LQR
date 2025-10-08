local rx = require("reactivex")
local Delay = require("viz.observable_delay")
local TimeUtils = require("viz.time_utils")

describe("Observable delay sourceTime stamping", function()
	local originalTimeFn

	before_each(function()
		rx.scheduler.reset()
		originalTimeFn = TimeUtils.nowEpochSeconds
	end)

	after_each(function()
		if originalTimeFn then
			TimeUtils.nowEpochSeconds = originalTimeFn
		end
		rx.scheduler.reset()
	end)

	local function buildDelayed(records, delayOpts)
		local base = rx.Observable.create(function(observer)
			for _, record in ipairs(records) do
				observer:onNext(record)
			end
			observer:onCompleted()
		end)
		return Delay.withDelay(base, delayOpts or { minDelay = 0, maxDelay = 0 })
	end

	it("stamps sourceTime when missing at emission time", function()
		local current = 1000
		TimeUtils.nowEpochSeconds = function()
			current = current + 0.5
			return current
		end
		local delayed = buildDelayed({ { RxMeta = {} } }, { minDelay = 0.1, maxDelay = 0.1 })
		local emissions = {}
		delayed:subscribe(function(value)
			emissions[#emissions + 1] = value
		end)
		rx.scheduler.update(0.05)
		assert.are.equal(nil, emissions[1])
		rx.scheduler.update(0.1)
		assert.are.equal(1, #emissions)
		assert.are.equal(current, emissions[1].RxMeta.sourceTime)
	end)

	it("preserves an existing sourceTime", function()
		local existing = 987654
		local delayed = buildDelayed({ { RxMeta = { sourceTime = existing } } })
		local emissions = {}
		delayed:subscribe(function(value)
			emissions[#emissions + 1] = value
		end)
		rx.scheduler.update(0)
		assert.are.equal(1, #emissions)
		assert.are.equal(existing, emissions[1].RxMeta.sourceTime)
	end)
end)
