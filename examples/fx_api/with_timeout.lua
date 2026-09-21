#!/usr/bin/env lua
-- with_timeout.lua — Core · fx.with_timeout
--
-- 用途：限时包裹一段 Cont；超时 → Failed(on_timeout，默认 "timeout")，并取消子树。
-- 参数：ma, seconds≥0, opts.on_timeout（任意错误值）。
-- 时间基：跟随 opts.scheduler（GameSim / VirtualClock = 游戏时间）。
-- 常见坑：与 Cont.withEnv __Timeout__ 不同——本 API 包整段 Cont，非逐步属性。
-- tabMachine 对照：近似带 deadline 的 join。
--
-- 仓库根：lua examples/fx_api/with_timeout.lua

package.path = "src/?.lua;examples/fx_api/?.lua;" .. package.path

local C = require("_common")
local Cont, fx = C.Cont, C.fx

local M = {}

function M.run(opts)
  opts = opts or {}
  C.quiet = not not opts.quiet

  C.section("限时内完成")
  local r, sim = C.run_sim(fx.with_timeout(
    fx.wait(0.10) >> function(_) return Cont.unit("ok") end,
    0.50
  ))
  C.need(r.ok and r.value == "ok")
  C.need(sim:now() < 0.30)
  C.log("  value=%s t=%.2f", tostring(r.value), sim:now())

  C.section("超时 → Failed(timeout)")
  local r2, sim2 = C.run_sim(fx.with_timeout(
    fx.wait(1.0) >> function(_) return Cont.unit("late") end,
    0.15
  ))
  C.need(r2.failed and r2.error == "timeout")
  C.need(sim2:now() >= 0.15 - 1e-9 and sim2:now() < 0.35)
  C.log("  error=%s t=%.2f", tostring(r2.error), sim2:now())

  C.section("自定义 on_timeout")
  local r3 = select(1, C.run_sim(fx.with_timeout(
    fx.wait(1.0), 0.05, { on_timeout = "deadline" }
  )))
  C.need(r3.failed and r3.error == "deadline")
  C.log("  error=%s", tostring(r3.error))

  if not C.quiet then C.ok("with_timeout") end
  return true
end

if arg and arg[0] and arg[0]:match("with_timeout%.lua$") then
  local quiet = arg[1] == "test" or arg[1] == "--quiet"
  M.run({ quiet = quiet })
  if quiet then C.ok("with_timeout") end
end

return M
