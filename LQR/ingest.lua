-- LQR/ingest.lua -- public facade for ingest/buffer/drain utilities.

--- @class LQRIngestBufferOpts
--- @field name string
--- @field mode "dedupSet"|"latestByKey"|"queue"
--- @field capacity integer
--- @field key fun(item:any):string|number|nil
--- @field lane fun(item:any):string|nil
--- @field lanePriority fun(laneName:string):integer
--- @field ordering "none"|"fifo"
--- @field onDrainStart fun(info:table)|nil
--- @field onDrainEnd fun(info:table)|nil
--- @field onDrop fun(info:table)|nil
--- @field onReplace fun(info:table)|nil

--- @class LQRIngestBuffer
--- @field name string
--- @field mode string
--- @field capacity integer
--- @field ingest fun(self:LQRIngestBuffer, item:any)
--- @field drain fun(self:LQRIngestBuffer, opts:table):table
--- @field metrics_get fun(self:LQRIngestBuffer):table
--- @field metrics_reset fun(self:LQRIngestBuffer)
--- @field clear fun(self:LQRIngestBuffer)

--- @class LQRIngestSchedulerOpts
--- @field name string
--- @field maxItemsPerTick integer

--- @class LQRIngestScheduler
--- @field addBuffer fun(self:LQRIngestScheduler, buffer:LQRIngestBuffer, opts:table)
--- @field drainTick fun(self:LQRIngestScheduler, handleFn:function):table
--- @field metrics_get fun(self:LQRIngestScheduler):table
--- @field metrics_reset fun(self:LQRIngestScheduler)

--- @class LQRIngest
--- @field buffer fun(opts:LQRIngestBufferOpts):LQRIngestBuffer
--- @field scheduler fun(opts:LQRIngestSchedulerOpts):LQRIngestScheduler

local Buffer = require("LQR/ingest/buffer")
local Scheduler = require("LQR/ingest/scheduler")

local Ingest = {}

--- Create a new ingest buffer.
--- @param opts LQRIngestBufferOpts
--- @return LQRIngestBuffer
function Ingest.buffer(opts)
	return Buffer.new(opts)
end

--- Create a scheduler helper to drain multiple buffers.
--- @param opts LQRIngestSchedulerOpts
--- @return LQRIngestScheduler
function Ingest.scheduler(opts)
	return Scheduler.new(opts or {})
end

--- @type LQRIngest
return Ingest
