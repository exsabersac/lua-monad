#!/usr/bin/env lua
-- game_sim_parallel.lua — when_all 在游戏时间上并行（wall 不参与；tick 推进）
-- 在仓库根目录执行：lua examples/game_sim_parallel.lua

package.path = "src/?.lua;" .. package.path

local Cont = require("cont")
local fx = require("fx")
local GameSim = require("game_sim")

local print, assert = print, assert

print("=== when_all on game time ===")
local sim = GameSim.new({ dt = 0.05 })

local pipe = Cont.withEnv(function(_ENV)
  function step(_)
    return fx.when_all({
      fx.wait(0.30) >> function(_) return Cont.unit("A") end,
      fx.wait(0.50) >> function(_) return Cont.unit("B") end,
      fx.wait(0.20) >> function(_) return Cont.unit("C") end,
    }) >> function(vals)
      return Cont.unit(vals)
    end
  end
end)

local wall0 = os.clock()
local r = sim:run(pipe(nil))
local wall_elapsed = os.clock() - wall0

assert(r.ok)
assert(r.value[1] == "A" and r.value[2] == "B" and r.value[3] == "C")
-- 游戏时间 ≈ max(0.30,0.50,0.20)=0.50，而非串行 1.0
assert(sim:now() >= 0.50 - 1e-9)
assert(sim:now() < 0.60)
-- 墙钟应远小于游戏等待（无 busy_wait）
assert(wall_elapsed < 0.05, "wall should be tiny, got " .. tostring(wall_elapsed))

print(string.format("  values=%s,%s,%s game_time=%.2f wall=%.4fs",
  r.value[1], r.value[2], r.value[3], sim:now(), wall_elapsed))

print("=== fork/join on game time ===")
sim = GameSim.new({ dt = 0.05 })
r = sim:run(
  fx.fork(fx.wait(0.4) >> function(_) return Cont.unit(1) end) >> function(h1)
    return fx.fork(fx.wait(0.4) >> function(_) return Cont.unit(2) end) >> function(h2)
      return fx.join_handles({ h1, h2 })
    end
  end
)
assert(r.ok and r.value[1] == 1 and r.value[2] == 2)
assert(sim:now() >= 0.4 - 1e-9 and sim:now() < 0.55)
print(string.format("  join ok game_time=%.2f", sim:now()))

print("=== channel mailbox on game time ===")
sim = GameSim.new({ dt = 0.05 })
local ch = fx.chan(1)
local got
local consumer = sim:start_flow(nil,
  fx.recv(ch) >> function(v)
    got = v
    return Cont.unit(v)
  end
)
assert(not consumer.done)
local producer = sim:start_flow(nil, fx.send(ch, "mail"))
sim:tick(0)
assert(consumer.done and producer.done and got == "mail")
assert(sim:now() == 0)
print(string.format("  mailbox ok value=%s game_time=%.2f", tostring(got), sim:now()))

print("game_sim_parallel OK")
