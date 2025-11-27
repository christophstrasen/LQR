local rx = require("reactivex")

-- Create an observable that produces a single value and print it.
rx.Observable.of(42):subscribe(print)
