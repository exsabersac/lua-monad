#!/usr/bin/env lua
-- when_all_any.lua — Core · fx.when_all / when_any
--
-- 用途：
--   when_all(mas) → 全部成功后 resume 数组；任一 Failed/Aborted 则整体失败
--   when_any(mas) → 先完成者胜；resume 为 {value, index?} 形态依赖实现（此处取胜者值）
-- 与 fork+join_handles：when_all ≈ 结构化一次汇合；lanes 是命名版。
-- Sugar 别名：join_all / join_any；顶层 run_all / run_any。
-- 常见坑：when_any 未取消兄弟时其它任务仍可能跑完（看 cancel 策略）。
-- tabMachine 对照：join 全员 / select 竞速。
--
-- 仓库根：lua examples/fx_api/when_all_any.lua

package.path = "src/?.lua;examples/fx_api/?.lua;" .. package.path

local C = require("_common")
local Cont, fx = C.Cont, C.fx

local M = {}

function M.run(opts)
  opts = opts or {}
  C.quiet = not not opts.quiet

  C.section("when_all：游戏时间 ≈ max(0.2,0.4,0.3)")
  local r, sim = C.run_sim(fx.when_all({
    fx.wait(0.20) >> function(_) return Cont.unit("A") end,
    fx.wait(0.40) >> function(_) return Cont.unit("B") end,
    fx.wait(0.30) >> function(_) return Cont.unit("C") end,
  }))
  C.need(r.ok and r.value[1] == "A" and r.value[2] == "B" and r.value[3] == "C")
  C.need(sim:now() >= 0.40 - 1e-9 and sim:now() < 0.55)
  C.log("  values=%s,%s,%s t=%.2f", r.value[1], r.value[2], r.value[3], sim:now())

  C.section("when_any：短 wait 先胜")
  local r2, sim2 = C.run_sim(fx.when_any({
    fx.wait(0.40) >> function(_) return Cont.unit("slow") end,
    fx.wait(0.10) >> function(_) return Cont.unit("fast") end,
  }))
  C.need(r2.ok, "when_any ok")
  -- session 结果：value 为胜者值，可能带 index
  local v = r2.value
  if type(v) == "table" and v.value ~= nil then
    C.need(v.value == "fast", "winner fast")
    C.log("  winner=%s index=%s t=%.2f", tostring(v.value), tostring(v.index), sim2:now())
  else
    C.need(v == "fast", "winner fast scalar")
    C.log("  winner=%s t=%.2f", tostring(v), sim2:now())
  end
  C.need(sim2:now() < 0.35, "should finish near 0.10")

  if not C.quiet then C.ok("when_all_any") end
  return true
end

if arg and arg[0] and arg[0]:match("when_all_any%.lua$") then
  local quiet = arg[1] == "test" or arg[1] == "--quiet"
  M.run({ quiet = quiet })
  if quiet then C.ok("when_all_any") end
end

return M
