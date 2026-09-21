#!/usr/bin/env lua
-- game_sim_flow.lua — GameSim：游戏时间 wait、pause、wait_event、实体销毁/finally
-- 在仓库根目录执行：lua examples/game_sim_flow.lua
--
-- 不走墙钟 busy_wait；全部由 sim:tick / sim:run 推进游戏时间。

package.path = "src/?.lua;" .. package.path

local Cont = require("cont")
local Coro = require("coro")
local fx = require("fx")
local GameSim = require("game_sim")

local print, assert, tostring, format = print, assert, tostring, string.format

------------------------------------------------------------
-- 1. wait + pause：暂停时时间不走，恢复后继续
------------------------------------------------------------
print("=== 1. wait + pause ===")
local sim = GameSim.new({ dt = 0.1 })
local log = {}

local pipe = Cont.withEnv(function(_ENV)
  function step(_)
    log[#log + 1] = "before:" .. format("%.1f", sim:now())
    return fx.wait(0.5) >> function(_)
      log[#log + 1] = "after:" .. format("%.1f", sim:now())
      return Cont.unit("ok")
    end
  end
end)

local flow = sim:start_flow(nil, pipe(nil))
assert(not flow.done)
sim:tick(0.2) -- t=0.2
assert(math.abs(sim:now() - 0.2) < 1e-9)
assert(not flow.done)
sim:set_paused(true)
sim:tick(1.0) -- pause：时间仍为 0.2
assert(math.abs(sim:now() - 0.2) < 1e-9)
assert(not flow.done)
sim:set_paused(false)
sim:tick(0.3) -- t=0.5 → wait 到期
assert(flow.done and flow.result.ok and flow.result.value == "ok")
assert(log[1] == "before:0.0" and log[2] == "after:0.5", table.concat(log, ","))
print("  pause 期间未唤醒；恢复后 @0.5 完成")

------------------------------------------------------------
-- 2. wait_event
------------------------------------------------------------
print("=== 2. wait_event ===")
sim = GameSim.new()
local got
local ev_pipe = Cont.withEnv(function(_ENV)
  function step(_)
    return fx.wait_event("hit", function(p)
      return p and p.dmg and p.dmg >= 10
    end) >> function(payload)
      got = payload
      return Cont.unit(payload.dmg)
    end
  end
end)
flow = sim:start_flow(nil, ev_pipe(nil))
assert(not flow.done)
sim:emit("hit", { dmg = 3 }) -- 过滤不匹配
assert(not flow.done)
sim:emit("hit", { dmg = 12 })
assert(flow.done and flow.result.ok and flow.result.value == 12)
assert(got and got.dmg == 12)
print("  filter 生效，payload 已 resume")

------------------------------------------------------------
-- 3. 实体销毁 → cancel + finally
------------------------------------------------------------
print("=== 3. entity destroy → finally ===")
sim = GameSim.new({ dt = 0.05 })
local closed = false
local ent = sim:spawn_entity("mob")

local life = Cont.withEnv(function(_ENV)
  function init(_)
    print("  [init] open")
    return Cont.unit(true)
  end
  function work(_)
    return fx.wait(2.0) >> function(_)
      return Cont.unit("should-not")
    end
  end
  function finally(outcome)
    print("  [finally]", outcome.status, tostring(outcome.reason))
    closed = true
    return Cont.unit(true)
  end
end)

flow = sim:start_flow(ent, life(nil))
sim:tick(0.1)
assert(not flow.done)
sim:destroy_entity(ent.id)
assert(flow.done and flow.result.stopped)
assert(flow.result.reason == "entity_destroyed")
assert(closed, "finally must run on entity destroy")
print("  destroy 后 finally 已跑，flow stopped")

------------------------------------------------------------
-- 4. sim:run 一次性跑完（无墙钟）
------------------------------------------------------------
print("=== 4. sim:run ===")
sim = GameSim.new({ dt = 0.25 })
local r = sim:run(fx.wait(1.0) >> function(_)
  return Cont.unit(sim:now())
end)
assert(r.ok)
assert(r.value >= 1.0 - 1e-9)
assert(sim:now() >= 1.0 - 1e-9)
print("  run 完成，game_time=", sim:now(), "value=", r.value)

------------------------------------------------------------
-- 5. 自定义异步 kind（anim mock）
------------------------------------------------------------
print("=== 5. register async anim ===")
sim = GameSim.new({ dt = 0.1 })
sim:register("anim", function(req, resume)
  sim:schedule(req.seconds or 0.3, function()
    resume({ ok = true, name = req.name })
  end)
end, { async = true })

r = sim:run(Coro.yield({ kind = "anim", name = "slash", seconds = 0.3 }) >> function(res)
  return Cont.unit(res.name)
end)
assert(r.ok and r.value == "slash")
assert(sim:now() >= 0.3 - 1e-9)
print("  anim mock @ game_time", sim:now())

print("game_sim_flow OK")
