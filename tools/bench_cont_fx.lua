#!/usr/bin/env lua
-- bench_cont_fx.lua — Cont / >> / chain / fx_sched 热路径粗测（分配敏感）
-- 在仓库根目录：
--   lua5.3 tools/bench_cont_fx.lua
--   lua5.3 tools/bench_cont_fx.lua 50000
-- 结果写入 stdout；亦可重定向。非严格 microbench（含 GC）。
-- 详见 tools/README.md、docs/性能与工具.md

package.path = "src/?.lua;" .. package.path

local Cont = require("cont")
local Coro = require("coro")
local fx = require("fx")
local Sched = require("fx_sched")
local Scheduler = require("scheduler")

local function time_call(n, fn)
  collectgarbage("collect")
  collectgarbage("collect")
  local m0 = collectgarbage("count")
  local t0 = os.clock()
  fn(n)
  local t1 = os.clock()
  local m1 = collectgarbage("count")
  return t1 - t0, m1 - m0
end

local function fmt(sec, n, dkb)
  return string.format("%.3f s  (%.0f /s)  ΔKB=%.1f", sec, n / sec, dkb)
end

local N = tonumber(arg and arg[1]) or 20000

print(string.format("bench_cont_fx  N=%d  Lua %s", N, _VERSION))

-- 1) Cont.unit >> Cont.unit 链（热路径：每步 bind + unit 代理）
do
  local sec, dkb = time_call(N, function(n)
    local m = Cont.unit(0)
    for i = 1, n do
      m = m >> function(x)
        return Cont.unit(x + 1)
      end
    end
    assert(Cont.evalCont(m) == n)
  end)
  print("Cont >> chain     ", fmt(sec, N, dkb))
end

-- 1a) Cont.map 链（无每步 unit）
do
  local sec, dkb = time_call(N, function(n)
    local m = Cont.unit(0)
    for _ = 1, n do
      m = Cont.map(m, function(x)
        return x + 1
      end)
    end
    assert(Cont.evalCont(m) == n)
  end)
  print("Cont.map chain    ", fmt(sec, N, dkb))
end

-- 1b) Cont.chain 丢弃左值链（seq / .. 同路径）
do
  local sec, dkb = time_call(N, function(n)
    local m = Cont.unit(0)
    for i = 1, n do
      m = Cont.chain(m, Cont.unit(i))
    end
    assert(Cont.evalCont(m) == n)
  end)
  print("Cont.chain        ", fmt(sec, N, dkb))
end

-- 1c) Cont .. Cont（应与 chain 同实现）
do
  local sec, dkb = time_call(N, function(n)
    local m = Cont.unit(0)
    for i = 1, n do
      m = m .. Cont.unit(i)
    end
    assert(Cont.evalCont(m) == n)
  end)
  print("Cont .. chain     ", fmt(sec, N, dkb))
end

-- 2) Coro.start(unit) 紧循环
do
  local sec, dkb = time_call(N, function(n)
    for _ = 1, n do
      local a = Coro.start(Cont.unit(1))
      assert(Coro.isDone(a) and a.value == 1)
    end
  end)
  print("Coro.start unit   ", fmt(sec, N, dkb))
end

-- 3) fx.seq 短数组（经 fx.run → session；侧重 seq 构造 + 同步跑完）
do
  local sec, dkb = time_call(N, function(n)
    for _ = 1, n do
      local r = fx.run(fx.seq({ Cont.unit(1), Cont.unit(2), Cont.unit(3) }), {})
      assert(r.ok and r.value == 3)
    end
  end)
  print("fx.seq×3 run      ", fmt(sec, N, dkb))
end

-- 3b) 仅构造 fx.seq（无 session），观察 Cont.chain 收益
do
  local sec, dkb = time_call(N, function(n)
    for _ = 1, n do
      local m = fx.seq({ Cont.unit(1), Cont.unit(2), Cont.unit(3) })
      assert(Cont.evalCont(m) == 3)
    end
  end)
  print("fx.seq×3 eval     ", fmt(sec, N, dkb))
end

-- 4) VirtualClock wait(0) session
do
  local n = math.min(N, 5000)
  local sec, dkb = time_call(n, function(nn)
    for _ = 1, nn do
      local clock = Scheduler.VirtualClock()
      local flow = Sched.start_session(fx.wait(0) >> function(_)
        return Cont.unit(true)
      end, {}, { scheduler = clock })
      clock.advance(0)
      assert(flow.done and flow.result.ok)
    end
  end)
  print("session wait(0)   ", fmt(sec, n, dkb), string.format("(N=%d)", n))
end

print("done. （压力：Cont 代理表 + bind/unit；无 Yield 的 fx.run 走 sync fast-path；详见 docs/性能与工具.md）")
