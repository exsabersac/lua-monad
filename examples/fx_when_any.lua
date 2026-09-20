#!/usr/bin/env lua
-- fx_when_any.lua — Task.WhenAny 对照：竞速两路 wait，先到者胜，其余 cancelled
-- 在仓库根目录执行：lua examples/fx_when_any.lua

package.path = "src/?.lua;" .. package.path

local Cont = require("cont")
local fx = require("fx")
local sched = require("fx_sched")
local print, assert, tostring = print, assert, tostring

print("=== when_any：0.03 vs 0.08，短者胜出 ===")
local t0 = sched.now()
local r = fx.run_any({
  fx.wait(0.08) >> function(_) return Cont.unit("slow") end,
  fx.wait(0.03) >> function(_) return Cont.unit("fast") end,
}, nil, { verbose_wait = true })
local elapsed = sched.now() - t0
assert(r.ok, "run_any should succeed")
assert(r.index == 2, "winner should be task #2")
assert(r.value == "fast")
print(string.format("  winner index=%d value=%s elapsed=%.3fs", r.index, tostring(r.value), elapsed))
assert(elapsed < 0.06, "should finish near the shorter wait")
assert(elapsed >= 0.02, "should still wait roughly the shorter delay")

print("\n=== fx.when_any Cont 组合子 ===")
local race = fx.when_any({
  fx.wait(0.05) >> function(_) return Cont.unit("a") end,
  fx.wait(0.01) >> function(_) return Cont.unit("b") end,
})
local r2 = fx.run(race, nil, { verbose_wait = true })
assert(r2.ok)
assert(r2.value.index == 2 and r2.value.value == "b")
print("  Cont when_any →", r2.value.value, "index", r2.value.index)

print("\nfx_when_any OK")
