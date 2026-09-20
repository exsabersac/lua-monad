#!/usr/bin/env lua
-- fx_when_all.lua — Task.WhenAll 对照：两路 wait 并行；wall clock ≈ max 而非 sum
-- 在仓库根目录执行：lua examples/fx_when_all.lua
--
-- C# 对照：
--   await Task.WhenAll(Task.Delay(50), Task.Delay(50));  // ~50ms 而非 100ms
--   await Task.WhenAll(ConnectAsync(), ClickAsync(), Delay(...));

package.path = "src/?.lua;" .. package.path

local Cont = require("cont")
local fx = require("fx")
local print, assert, tostring = print, assert, tostring

------------------------------------------------------------
-- 1. 两路 wait(0.05)：并行 wall clock 应明显小于串行 0.10
------------------------------------------------------------
print("=== when_all：两路 wait(0.05) 并行 ===")
local sched = require("fx_sched")
local t0 = sched.now()
local r1 = fx.run_all({
  fx.wait(0.05),
  fx.wait(0.05),
}, nil, { verbose_wait = true })
local elapsed = sched.now() - t0
assert(r1.ok, "run_all should succeed")
assert(type(r1.values) == "table" and #r1.values == 2)
assert(r1.values[1] == true and r1.values[2] == true)
print(string.format("  elapsed=%.3fs (期望 < 0.09；串行会 ≈ 0.10)", elapsed))
assert(elapsed < 0.09, "parallel waits should finish under 0.09s, got " .. tostring(elapsed))
assert(elapsed >= 0.04, "should still wait roughly 0.05s")

------------------------------------------------------------
-- 2. Cont 组合子 fx.when_all 经 fx.run
------------------------------------------------------------
print("\n=== fx.when_all Cont 组合子 + connect/click/wait ===")
local bundle = fx.when_all({
  fx.connect("a"),
  fx.click("b"),
  fx.wait(0.03),
})
local instant = {
  wait = function(req)
    -- 单任务 fx.run 路径仍会调用；此处并行子任务的 wait 由调度器时间轮处理
    return true
  end,
  connect = function(req)
    print("  [handler] connect " .. tostring(req.host))
    return { ok = true, host = req.host }
  end,
  click = function(req)
    print("  [handler] click " .. tostring(req.target))
    return { ok = true, target = req.target }
  end,
}
local t1 = sched.now()
local r2 = fx.run(bundle, instant, { verbose_wait = true })
local e2 = sched.now() - t1
assert(r2.ok)
local vals = r2.value
assert(vals[1].host == "a")
assert(vals[2].target == "b")
assert(vals[3] == true)
print(string.format("  values ok; elapsed=%.3fs (含 wait 0.03)", e2))
assert(e2 < 0.08)

------------------------------------------------------------
-- 3. 结果顺序与任务下标一致
------------------------------------------------------------
print("\n=== when_all 结果顺序 ===")
local r3 = fx.run_all({
  Cont.unit("first"),
  Cont.unit("second"),
  Cont.unit("third"),
}, instant)
assert(r3.ok)
assert(r3.values[1] == "first" and r3.values[2] == "second" and r3.values[3] == "third")
print("  order:", r3.values[1], r3.values[2], r3.values[3])

print("\nfx_when_all OK")
