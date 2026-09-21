#!/usr/bin/env lua
-- map_parallel.lua — Sugar · fx.map_parallel / for_each_parallel
--
-- 用途：有限并发滑动窗口对数组 map；结果按输入下标排列。
-- 参数：items, worker(item,index)→Cont, opts.concurrency（默认 4）。
-- 与 Core：内部 = fork + join 窗口；有界工人池也可用 chan。
-- 何时用 Sugar：固定并发、要按序结果数组；动态流水线用 chan 更合适。
-- 常见坑：worker 闭包共享可变状态需自同步；concurrency=1 即串行。
-- tabMachine 对照：无直接对应。
--
-- 仓库根：lua examples/fx_api/map_parallel.lua

package.path = "src/?.lua;examples/fx_api/?.lua;" .. package.path

local C = require("_common")
local Cont, fx = C.Cont, C.fx

local M = {}

function M.run(opts)
  opts = opts or {}
  C.quiet = not not opts.quiet

  C.section("map_parallel concurrency=2，4 项各 wait 0.10 → 游戏时间≈0.20")
  local items = { "a", "b", "c", "d" }
  local r, sim = C.run_sim(fx.map_parallel(items, function(item, i)
    return fx.wait(0.10) >> function(_)
      return Cont.unit(item .. tostring(i))
    end
  end, { concurrency = 2 }))
  C.need(r.ok)
  C.need(r.value[1] == "a1" and r.value[4] == "d4")
  -- 两批：≈0.20
  C.need(sim:now() >= 0.20 - 1e-9 and sim:now() < 0.40)
  C.log("  results=%s,%s,%s,%s t=%.2f",
    r.value[1], r.value[2], r.value[3], r.value[4], sim:now())

  C.section("for_each_parallel → true")
  local n = 0
  local r2 = select(1, C.run_sim(fx.for_each_parallel({ 1, 2, 3 }, function(x)
    return Cont.unit(true) >> function(_)
      n = n + x
      return Cont.unit(true)
    end
  end, { concurrency = 3 })))
  C.need(r2.ok and r2.value == true and n == 6)
  C.log("  sum=%d", n)

  if not C.quiet then C.ok("map_parallel") end
  return true
end

if arg and arg[0] and arg[0]:match("map_parallel%.lua$") then
  local quiet = arg[1] == "test" or arg[1] == "--quiet"
  M.run({ quiet = quiet })
  if quiet then C.ok("map_parallel") end
end

return M
