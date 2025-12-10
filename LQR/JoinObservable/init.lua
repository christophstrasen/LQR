require("LQR.bootstrap")

local Core = require("LQR.JoinObservable.core")
local Chain = require("LQR.JoinObservable.chain")

local JoinObservable = {}

JoinObservable.createJoinObservable = Core.createJoinObservable
JoinObservable.chain = Chain.chain

return JoinObservable
