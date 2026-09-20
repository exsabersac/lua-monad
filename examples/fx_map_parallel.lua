#!/usr/bin/env lua
-- fx_map_parallel.lua — 有限并发池：6 项 concurrency=2，墙钟 ≈ 3 批而非串行 6 份
-- 在仓库根目录执行：lua examples/fx_map_parallel.lua
--
-- 对照：
--   when_all(全部)     = 无限并发（一次全开）
--   map_parallel(..., {concurrency=N}) = 同时最多 N 个 worker

package.path = "src/?.lua;" .. package.path

local Cont = require("cont")
local fx = require("fx")
local sched = require("fx_sched")
local print, assert, tostring = print, assert, tostring

------------------------------------------------------------
-- 1. 6 项 wait(0.04)，concurrency=2 → wall ≈ 3×0.04，串行会 ≈ 0.24
------------------------------------------------------------
print("=== map_parallel：6 项 wait(0.04)，concurrency=2 ===")
local items = { "a", "b", "c", "d", "e", "f" }
local t0 = sched.now()
local pipe = fx.map_parallel(items, function(item, index)
  return fx.wait(0.04) >> function(_)
    return Cont.unit(item .. tostring(index))
  end
end, { concurrency = 2 })
local r1 = fx.run(pipe, nil, { verbose_wait = true })
local e1 = sched.now() - t0
assert(r1.ok, "map_parallel should succeed")
assert(#r1.value == 6)
for i, item in ipairs(items) do
  assert(r1.value[i] == item .. tostring(i), "order mismatch at " .. i)
end
print(string.format("  results=%s,%s,…,%s elapsed=%.3fs",
  r1.value[1], r1.value[2], r1.value[6], e1))
print("  期望：约 0.12（3 批）而非串行 ≈ 0.24；且明显小于全开 when_all 的约束之外")
assert(e1 < 0.20, "bounded pool wall should be < 0.20, got " .. tostring(e1))
assert(e1 >= 0.10, "three batches of 0.04 → >= 0.10, got " .. tostring(e1))
-- 串行 6×0.04=0.24；两批并行应明显更快
assert(e1 < 0.22, "should beat serial-all")

------------------------------------------------------------
-- 2. 结果顺序与输入对齐；concurrency 默认
------------------------------------------------------------
print("\n=== 顺序与空列表 ===")
local r2 = fx.run(fx.map_parallel({ 10, 20, 30 }, function(x, i)
  return Cont.unit(x + i)
end))
assert(r2.ok and r2.value[1] == 11 and r2.value[2] == 22 and r2.value[3] == 33)
print("  order ok:", r2.value[1], r2.value[2], r2.value[3])

local r0 = fx.run(fx.map_parallel({}, function(_x, _i) return Cont.unit(1) end))
assert(r0.ok and type(r0.value) == "table" and #r0.value == 0)
print("  empty → {}")

------------------------------------------------------------
-- 3. for_each_parallel 别名
------------------------------------------------------------
print("\n=== for_each_parallel ===")
local seen = {}
local r3 = fx.run(fx.for_each_parallel({ "x", "y" }, function(item, i)
  seen[#seen + 1] = item .. i
  return Cont.unit(true)
end, { concurrency = 1 }))
assert(r3.ok and r3.value == true)
assert(seen[1] == "x1" and seen[2] == "y2")
print("  for_each saw", seen[1], seen[2])

print("\nfx_map_parallel OK")
