local Core = require("JoinObservable.core")
local Chain = require("JoinObservable.chain")

local JoinObservable = {}

JoinObservable.createJoinObservable = Core.createJoinObservable
JoinObservable.chain = Chain.chain

return JoinObservable
