-- Cont-based CPS coroutine (single coro, NOT Lua native coroutine).
-- Answer type: Done { tag="done", value } | Yielded { tag="yielded", value, cont }

local Cont = require("cont")

local function Done(v)
  return { tag = "done", value = v }
end

local function Yielded(v, cont)
  return { tag = "yielded", value = v, cont = cont }
end

local function isDone(a)
  return type(a) == "table" and a.tag == "done"
end

local function isYielded(a)
  return type(a) == "table" and a.tag == "yielded"
end

-- yield : a -> Cont (Done|Yielded) ()
-- Suspends with value a; resume supplies the next value into the continuation.
local function yield(v)
  return function(k)
    return Yielded(v, k)
  end
end

-- start : Cont (Done|Yielded) a -> Done|Yielded
-- Run a Cont computation whose answer type is Done|Yielded.
local function start(ma)
  return Cont.runCont(ma, function(a)
    return Done(a)
  end)
end

-- resume : Yielded -> b -> Done|Yielded
-- Feed `b` into the suspended continuation.
local function resume(y, b)
  assert(isYielded(y), "resume: expected Yielded")
  return y.cont(b)
end

return {
  Done = Done,
  Yielded = Yielded,
  isDone = isDone,
  isYielded = isYielded,
  yield = yield,
  start = start,
  resume = resume,
  Cont = Cont,
}
