#!/usr/bin/env lua
-- Monad law tests + Cont-based CPS coro demo assertions.
-- Exit non-zero on failure.

package.path = "src/?.lua;" .. package.path

local Maybe = require("maybe")
local List = require("list")
local State = require("state")
local Status = require("status")
local Cont = require("cont")
local Coro = require("coro")

local failures = 0

local function eq(a, b)
  if type(a) ~= type(b) then return false end
  if type(a) ~= "table" then return a == b end
  -- shallow structural compare for tagged values / arrays
  local ka, kb = 0, 0
  for k in pairs(a) do ka = ka + 1 end
  for k in pairs(b) do kb = kb + 1 end
  if ka ~= kb then return false end
  for k, v in pairs(a) do
    if not eq(v, b[k]) then return false end
  end
  return true
end

local function assert_eq(actual, expected, msg)
  if not eq(actual, expected) then
    failures = failures + 1
    io.stderr:write("FAIL: " .. (msg or "?") .. "\n")
    return false
  end
  io.stdout:write("ok: " .. (msg or "?") .. "\n")
  return true
end

local function assert_true(cond, msg)
  if not cond then
    failures = failures + 1
    io.stderr:write("FAIL: " .. (msg or "?") .. "\n")
    return false
  end
  io.stdout:write("ok: " .. (msg or "?") .. "\n")
  return true
end

------------------------------------------------------------
-- Helper: check left/right identity + associativity for a monad
------------------------------------------------------------
local function test_laws(name, M, samples, f, g, run)
  run = run or function(x) return x end
  -- Left identity:  unit(a) >>= f  ==  f(a)
  for _, a in ipairs(samples) do
    local left = run(M.bind(M.unit(a), f))
    local right = run(f(a))
    assert_eq(left, right, name .. " left identity a=" .. tostring(a))
  end
  -- Right identity:  m >>= unit  ==  m
  for _, ma in ipairs({ M.unit(samples[1]), f(samples[1]) }) do
    local left = run(M.bind(ma, M.unit))
    local right = run(ma)
    assert_eq(left, right, name .. " right identity")
  end
  -- Associativity: (m >>= f) >>= g  ==  m >>= (\\x -> f(x) >>= g)
  local m0 = M.unit(samples[1])
  local left = run(M.bind(M.bind(m0, f), g))
  local right = run(M.bind(m0, function(x) return M.bind(f(x), g) end))
  assert_eq(left, right, name .. " associativity")
end

------------------------------------------------------------
-- Maybe
------------------------------------------------------------
do
  local f = function(x) return Maybe.Just(x + 1) end
  local g = function(x) return Maybe.Just(x * 2) end
  test_laws("Maybe", Maybe, { 0, 1, 42 }, f, g)

  assert_eq(Maybe.bind(Maybe.Nothing(), f), Maybe.Nothing(), "Maybe Nothing short-circuit")
  assert_eq(Maybe.then_(Maybe.Just(3), function(x) return x * 10 end), Maybe.Just(30), "Maybe then_")
end

------------------------------------------------------------
-- List
------------------------------------------------------------
do
  local f = function(x) return { x, x + 1 } end
  local g = function(x) return { x * 10 } end
  test_laws("List", List, { 1, 2 }, f, g)

  assert_eq(List.bind({ 1, 2 }, function(x) return { x, x * 2 } end),
            { 1, 2, 2, 4 }, "List bind flatten")
  assert_eq(List.bind({}, f), {}, "List empty bind")
end

------------------------------------------------------------
-- State
------------------------------------------------------------
do
  local f = function(x)
    return State.bind(State.modify(function(s) return s + 1 end), function()
      return State.unit(x + 1)
    end)
  end
  local g = function(x)
    return State.bind(State.get(), function(s)
      return State.unit(x + s)
    end)
  end
  local run = function(ma)
    local a, s = State.runState(ma, 0)
    return { a = a, s = s }
  end
  test_laws("State", State, { 5, 10 }, f, g, run)

  local prog = State.bind(State.get(), function(s)
    return State.bind(State.put(s + 10), function()
      return State.bind(State.modify(function(x) return x * 2 end), function()
        return State.get()
      end)
    end)
  end)
  local a, s = State.runState(prog, 3)
  assert_eq(a, 26, "State get/put/modify value")
  assert_eq(s, 26, "State get/put/modify state")
end

------------------------------------------------------------
-- Status
------------------------------------------------------------
do
  local f = function(x) return Status.Ok(x + 1) end
  local g = function(x) return Status.Ok(tostring(x)) end
  test_laws("Status", Status, { 1, 2 }, f, g)

  assert_eq(Status.bind(Status.Err("boom"), f), Status.Err("boom"), "Status Err short-circuit")
  assert_eq(Status.bind(Status.Ok(7), function(x) return Status.Err("nope") end),
            Status.Err("nope"), "Status Ok then Err")
end

------------------------------------------------------------
-- Cont
------------------------------------------------------------
do
  local f = function(x) return Cont.unit(x + 1) end
  local g = function(x) return Cont.unit(x * 3) end
  local run = function(ma)
    return Cont.runCont(ma, function(x) return x end)
  end
  test_laws("Cont", Cont, { 1, 4 }, f, g, run)

  local r = Cont.runCont(
    Cont.bind(Cont.unit(2), function(x)
      return Cont.unit(x + 3)
    end),
    function(x) return x * 10 end
  )
  assert_eq(r, 50, "Cont runCont")
end

------------------------------------------------------------
-- Coro (Cont-based CPS)
------------------------------------------------------------
do
  -- Simple: yield once then return
  local body = Cont.bind(Coro.yield(10), function(resume_val)
    return Cont.unit(resume_val + 100)
  end)

  local a1 = Coro.start(body)
  assert_true(Coro.isYielded(a1), "coro first step Yielded")
  assert_eq(a1.value, 10, "coro yield value")

  local a2 = Coro.resume(a1, 5)
  assert_true(Coro.isDone(a2), "coro second step Done")
  assert_eq(a2.value, 105, "coro final value")

  -- Two yields
  local body2 = Cont.bind(Coro.yield("a"), function(v1)
    return Cont.bind(Coro.yield("b:" .. tostring(v1)), function(v2)
      return Cont.unit("done:" .. tostring(v2))
    end)
  end)
  local s0 = Coro.start(body2)
  assert_true(Coro.isYielded(s0) and s0.value == "a", "coro2 yield a")
  local s1 = Coro.resume(s0, 1)
  assert_true(Coro.isYielded(s1) and s1.value == "b:1", "coro2 yield b")
  local s2 = Coro.resume(s1, 2)
  assert_true(Coro.isDone(s2) and s2.value == "done:2", "coro2 done")

  -- No yield: immediate Done
  local immediate = Coro.start(Cont.unit(99))
  assert_true(Coro.isDone(immediate) and immediate.value == 99, "coro no-yield Done")
end

------------------------------------------------------------
io.stdout:write("\n")
if failures > 0 then
  io.stderr:write(failures .. " failure(s)\n")
  os.exit(1)
else
  io.stdout:write("All tests passed.\n")
  os.exit(0)
end
