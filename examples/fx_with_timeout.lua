#!/usr/bin/env lua
-- fx_with_timeout.lua — 超时竞速：限时内成功；超时 → Failed("timeout")
-- 在仓库根目录执行：lua examples/fx_with_timeout.lua
--
-- 与 Cont.withEnv __Timeout__ 对照：属性逐步超时；本 API 包裹整段 Cont。

package.path = "src/?.lua;" .. package.path

local Cont = require("cont")
local fx = require("fx")
local sched = require("fx_sched")
local print, assert, tostring = print, assert, tostring

------------------------------------------------------------
-- 1. 限时内完成
------------------------------------------------------------
print("=== with_timeout：wait(0.03) 限时 0.10 → 成功 ===")
local t0 = sched.now()
local r1 = fx.run(fx.with_timeout(
  fx.wait(0.03) >> function(_) return Cont.unit("ok") end,
  0.10
), nil, { verbose_wait = true })
local e1 = sched.now() - t0
assert(r1.ok and r1.value == "ok", "should succeed under limit")
print(string.format("  value=%s elapsed=%.3fs", tostring(r1.value), e1))
assert(e1 < 0.08 and e1 >= 0.02)

------------------------------------------------------------
-- 2. 超时 → Failed("timeout")
------------------------------------------------------------
print("\n=== with_timeout：wait(0.10) 限时 0.03 → Failed(timeout) ===")
local t1 = sched.now()
local r2 = fx.run(fx.with_timeout(
  fx.wait(0.10) >> function(_) return Cont.unit("late") end,
  0.03
), nil, { verbose_wait = true })
local e2 = sched.now() - t1
assert(r2.ok == false and r2.failed == true, "should fail on timeout")
assert(r2.error == "timeout", "default error is \"timeout\"")
print(string.format("  failed error=%s elapsed=%.3fs (期望 ≈ 0.03)", tostring(r2.error), e2))
assert(e2 < 0.07 and e2 >= 0.02)

------------------------------------------------------------
-- 3. 自定义 on_timeout
------------------------------------------------------------
print("\n=== opts.on_timeout 自定义错误 ===")
local r3 = fx.run(fx.with_timeout(
  fx.wait(0.05) >> function(_) return Cont.unit(1) end,
  0.01,
  { on_timeout = "deadline-exceeded" }
))
assert(r3.failed and r3.error == "deadline-exceeded")
print("  error=", r3.error)

------------------------------------------------------------
-- 4. ma 自身 Failed 在超时前传播
------------------------------------------------------------
print("\n=== body 先 Failed（非超时）===")
local r4 = fx.run(fx.with_timeout(fx.fail("boom"), 1.0))
assert(r4.failed and r4.error == "boom")
print("  error=", r4.error)

print("\nfx_with_timeout OK")
