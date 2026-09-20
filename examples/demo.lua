#!/usr/bin/env lua
-- Short runnable demo of Lua Monad simulation + Cont CPS coro.

package.path = "src/?.lua;" .. package.path

local Maybe = require("maybe")
local List = require("list")
local State = require("state")
local Status = require("status")
local Cont = require("cont")
local Coro = require("coro")

print("=== Maybe ===")
local m = Maybe.bind(Maybe.Just(3), function(x)
  if x > 0 then return Maybe.Just(x * 2) else return Maybe.Nothing() end
end)
print("Just(3) >>= double:", m.tag, m.value)

print("\n=== List ===")
local xs = List.bind({ 1, 2, 3 }, function(x)
  return { x, x * 10 }
end)
io.write("bind flatten: ")
for i, v in ipairs(xs) do io.write(v .. (i < #xs and "," or "")) end
print()

print("\n=== State ===")
local prog = State.bind(State.get(), function(n)
  return State.bind(State.put(n + 1), function()
    return State.unit("was " .. tostring(n))
  end)
end)
local a, s = State.runState(prog, 41)
print("runState:", a, "new state:", s)

print("\n=== Status ===")
local ok = Status.bind(Status.Ok(10), function(x) return Status.Ok(x / 2) end)
local err = Status.bind(Status.Err("fail"), function(x) return Status.Ok(x) end)
print("Ok path:", ok.tag, ok.value)
print("Err path:", err.tag, err.error)

print("\n=== Cont + CPS coro ===")
local body = Cont.bind(Coro.yield("hello"), function(reply)
  return Cont.bind(Coro.yield("got:" .. tostring(reply)), function(reply2)
    return Cont.unit("finished with " .. tostring(reply2))
  end)
end)

local step = Coro.start(body)
while Coro.isYielded(step) do
  print("  yielded:", step.value)
  step = Coro.resume(step, #tostring(step.value))
end
print("  done:", step.value)
