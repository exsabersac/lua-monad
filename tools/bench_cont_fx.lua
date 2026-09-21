#!/usr/bin/env lua
-- bench_cont_fx.lua — Cont / >> / fx_sched 热路径粗测（分配敏感）
-- 在仓库根目录：lua5.3 tools/bench_cont_fx.lua
-- 结果写入 stdout；亦可重定向到 docs 旁注。非严格 microbench（含 GC）。

package.path = "src/?.lua;" .. package.path

local Cont = require("cont")
local Coro = require("coro")
local fx = require("fx")
local Sched = require("fx_sched")
local Scheduler = require("scheduler")

local function time_call(n, fn)
  collectgarbage("collect")
  local t0 = os.clock()
  fn(n)
  local t1 = os.clock()
  return t1 - t0
end

local function fmt(sec, n)
  return string.format("%.3f s  (%.0f /s)", sec, n / sec)
end

local N = tonumber(arg and arg[1]) or 20000

print(string.format("bench_cont_fx  N=%d  Lua %s", N, _VERSION))

-- 1) Cont.unit >> Cont.unit 链
do
  local sec = time_call(N, function(n)
    local m = Cont.unit(0)
    for i = 1, n do
      m = m >> function(x)
        return Cont.unit(x + 1)
      end
    end
    assert(Cont.evalCont(m) == n)
  end)
  print("Cont >> chain     ", fmt(sec, N))
end

-- 2) Coro.start(unit) 紧循环
do
  local sec = time_call(N, function(n)
    for _ = 1, n do
      local a = Coro.start(Cont.unit(1))
      assert(Coro.isDone(a) and a.value == 1)
    end
  end)
  print("Coro.start unit   ", fmt(sec, N))
end

-- 3) fx.seq 短数组
do
  local sec = time_call(N, function(n)
    for _ = 1, n do
      local r = fx.run(fx.seq({ Cont.unit(1), Cont.unit(2), Cont.unit(3) }), {})
      assert(r.ok and r.value == 3)
    end
  end)
  print("fx.seq×3 run      ", fmt(sec, N))
end

-- 4) VirtualClock wait(0) session
do
  local n = math.min(N, 5000)
  local sec = time_call(n, function(nn)
    for _ = 1, nn do
      local clock = Scheduler.VirtualClock()
      local flow = Sched.start_session(fx.wait(0) >> function(_)
        return Cont.unit(true)
      end, {}, { scheduler = clock })
      clock.advance(0)
      assert(flow.done and flow.result.ok)
    end
  end)
  print("session wait(0)   ", fmt(sec, n), string.format("(N=%d)", n))
end

print("done. （分配压力主要来自每步 Cont 代理表与闭包；工程路径请复用 session / 减少无谓 >>。）")
