local Observable = require 'reactivex.observable'

Observable.wrap = Observable.buffer
Observable['repeat'] = Observable.replicate
