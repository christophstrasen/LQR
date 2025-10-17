local package = require("package")
package.path = "./?.lua;./?/init.lua;" .. package.path
package.cpath = "./?.so;" .. package.cpath

require("bootstrap")

local rx = require("reactivex")
local Delay = require("viz_low_level.observable_delay")
local TimeUtils = require("viz_low_level.time_utils")

describe("Observable delay sourceTime stamping", function()
    local originalTimeFn
    local function withRandomSequence(sequence, fn)
        local originalRandom = math.random
        local index = 0
        math.random = function()
            index = index + 1
            if sequence[index] ~= nil then
                return sequence[index]
            end
            if #sequence > 0 then
                return sequence[#sequence]
            end
            return originalRandom()
        end
        local ok, result = pcall(fn)
        math.random = originalRandom
        if not ok then
            error(result)
        end
        return result
    end

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

    local UPDATE_STEP = 0.0001
    local MAX_STEPS = 10000
    local DELAY_TOLERANCE = 1e-3

    local function drainEmissions(delayOpts, records)
        local emissions = {}
        local completed = false
        local delayed = buildDelayed(records or { { RxMeta = {} }, { RxMeta = {} } }, delayOpts)
        delayed:subscribe(
            function(value)
                emissions[#emissions + 1] = {
                    value = value,
                    time = rx.scheduler.get().currentTime or 0,
                }
            end,
            function() end,
            function()
                completed = true
            end
        )
        local steps = 0
        while not completed and steps < MAX_STEPS do
            rx.scheduler.update(UPDATE_STEP)
            steps = steps + 1
        end
        assert.is_true(completed, "expected delayed stream to complete")
        return emissions
    end

    it("stamps sourceTime when missing at emission time", function()
        local current = 1000
        TimeUtils.nowEpochSeconds = function()
            current = current + 0.5
            return current
        end
        local emissions = drainEmissions({ minDelay = 0.1, maxDelay = 0.1 }, { { RxMeta = {} } }, 1)
        assert.are.equal(current, emissions[1].value.RxMeta.sourceTime)
    end)

    it("preserves an existing sourceTime", function()
        local existing = 987654
        local emissions = drainEmissions({}, { { RxMeta = { sourceTime = existing } } }, 1)
        assert.are.equal(existing, emissions[1].value.RxMeta.sourceTime)
    end)

    it("jittered mode spaces events along the timeline with randomness", function()
        local emissions
        -- Sequence: sampleDelay1, jitter1, sampleDelay2, jitter2
        withRandomSequence({ 0.0, 1.0, 1.0, 0.0 }, function()
            emissions = drainEmissions({ minDelay = 0.1, maxDelay = 0.3, delayMode = "jittered" })
        end)
        assert.are.equal(2, #emissions)
        assert.is_true(math.abs(emissions[1].time - 0.2) < DELAY_TOLERANCE)
        assert.is_true(math.abs(emissions[2].time - 0.3) < DELAY_TOLERANCE)
    end)

    it("ordered mode preserves deterministic cadence", function()
        local emissions
        withRandomSequence({ 0.0, 0.0 }, function()
            emissions = drainEmissions({ minDelay = 0.1, maxDelay = 0.1, delayMode = "ordered" })
        end)
        assert.is_true(math.abs(emissions[1].time - 0.1) < DELAY_TOLERANCE)
        assert.is_true(math.abs(emissions[2].time - 0.2) < DELAY_TOLERANCE)
    end)
end)
