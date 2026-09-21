#!/usr/bin/env lua
-- seq.lua — Sugar · fx.seq：顺序串联 Cont 数组
--
-- 用途：把 {ma1, ma2, …} 用 Cont.chain 串成一条；空数组 → unit(nil)。
-- 与 Core：等价于手写 ma1 >> function() return ma2 end >> …；无额外 yield kind。
-- 何时用 Sugar：步骤列表数据驱动时更短；固定两步直接 >> 更清晰。
-- 常见坑：seq 不捕获中间值数组（只要最后一步的值）；要折叠请自己 fold。
-- tabMachine 对照：seq / 顺序子节点。
--
-- 仓库根：lua examples/fx_api/seq.lua

package.path = "src/?.lua;examples/fx_api/?.lua;" .. package.path

local C = require("_common")
local Cont, fx = C.Cont, C.fx

local M = {}

function M.run(opts)
  opts = opts or {}
  C.quiet = not not opts.quiet

  C.section("seq 三步（游戏时间累加）")
  local log = {}
  local r, sim = C.run_sim(fx.seq({
    fx.wait(0.10) >> function(_)
      log[#log + 1] = "a"
      return Cont.unit(1)
    end,
    fx.wait(0.10) >> function(_)
      log[#log + 1] = "b"
      return Cont.unit(2)
    end,
    Cont.unit(true) >> function(_)
      log[#log + 1] = "c"
      return Cont.unit("done")
    end,
  }))
  C.need(r.ok and r.value == "done")
  C.need(table.concat(log, "") == "abc")
  C.need(sim:now() >= 0.20 - 1e-9 and sim:now() < 0.35)
  C.log("  value=%s log=%s t=%.2f", tostring(r.value), table.concat(log, ","), sim:now())

  C.section("空 seq → nil")
  local r2 = fx.run(fx.seq({}))
  C.need(r2.ok and r2.value == nil)
  C.log("  empty ok")

  C.section("Core 等价：手写 >>")
  local r3, sim3 = C.run_sim(
    fx.wait(0.05) >> function(_)
      return fx.wait(0.05) >> function(_)
        return Cont.unit("eq")
      end
    end
  )
  C.need(r3.ok and r3.value == "eq" and sim3:now() >= 0.10 - 1e-9)
  C.log("  core-equivalent t=%.2f", sim3:now())

  if not C.quiet then C.ok("seq") end
  return true
end

if arg and arg[0] and arg[0]:match("seq%.lua$") then
  local quiet = arg[1] == "test" or arg[1] == "--quiet"
  M.run({ quiet = quiet })
  if quiet then C.ok("seq") end
end

return M
