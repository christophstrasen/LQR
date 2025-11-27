local rx = require("reactivex")

local first = rx.Observable.fromRange(3)
local second = rx.Observable.fromRange(4, 6)
local third = rx.Observable.fromRange(7, 11, 2)

first:concat(second, third):dump("concat")

print("Equivalent to:")

rx.Observable.concat(first, second, third):dump("concat")
