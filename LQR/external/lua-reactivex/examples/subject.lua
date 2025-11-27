local rx = require("reactivex")

subject = rx.Subject.create()

subject:subscribe(function(x)
  print('observer a ' .. x)
end)

subject:subscribe(function(x)
  print('observer b ' .. x)
end)

subject:onNext(1)
subject(2)
subject:onNext(3)

-- This will print:
--
-- observer a 1
-- observer b 1
-- observer a 2
-- observer b 2
-- observer a 3
-- observer b 3
