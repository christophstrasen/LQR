local Core = require("JoinObservable.core")
local Chain = require("JoinObservable.chain")
local warnings = require("JoinObservable.warnings")

local JoinObservable = {}

JoinObservable.createJoinObservable = Core.createJoinObservable
JoinObservable.chain = Chain.chain
JoinObservable.setWarningHandler = warnings.setWarningHandler
JoinObservable.withWarningHandler = warnings.withWarningHandler

return JoinObservable
