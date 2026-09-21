#!/usr/bin/env lua
-- wait_until.lua — Core · fx.wait_until：轮询谓词直到为真
--
-- 用途：每 tick / interval 调 pred()；真值则 resume（值为 pred 返回值，若非 nil）。
-- 参数：pred()；opts.interval>=0 可选。
-- 需 schedule_poll（GameSim / FrameScheduler）；仅 VirtualClock 时用 schedule 自再预约模拟。
-- 常见坑：pred 有副作用且 interval 过大导致漏检；无 poll 后端时行为依赖宿主。
-- tabMachine 对照：近似 xx_update / 条件等待（无标签 DSL）。
--
-- 仓库根：lua examples/fx_api/wait_until.lua

package.path = "src/?.lua;examples/fx_api/?.lua;" .. package.path

local C = require("_common")
local Cont, fx = C.Cont, C.fx

local M = {}

function M.run(opts)
  opts = opts or {}
  C.quiet = not not opts.quiet

  C.section("fx.wait_until：flag 在 tick 中变真")
  local sim = C.new_sim({ dt = 0.05 })
  local flag = false
  local pipe = fx.wait_until(function()
    if flag then
      return "ready"
    end
    return false
  end, { interval = 0 }) -- 每帧 poll

  local flow = sim:start_flow(nil, pipe)
  sim:tick(0.1)
  C.need(not flow.done, "flag still false")
  flag = true
  sim:tick(0.05)
  C.need(flow.done and flow.result.ok, "should complete")
  C.need(flow.result.value == "ready", "resume with pred truthy value")
  C.log("  value=%s game_time=%.2f", tostring(flow.result.value), sim:now())

  if not C.quiet then C.ok("wait_until") end
  return true
end

if arg and arg[0] and arg[0]:match("wait_until%.lua$") then
  local quiet = arg[1] == "test" or arg[1] == "--quiet"
  M.run({ quiet = quiet })
  if quiet then C.ok("wait_until") end
end

return M
