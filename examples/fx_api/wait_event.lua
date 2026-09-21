#!/usr/bin/env lua
-- wait_event.lua — Core · fx.wait_event：等宿主事件（可带 filter）
--
-- 用途：挂起直到 GameSim.emit / listen 派发匹配事件。
-- 参数：name（必填）；filter(payload)→bool 可选。
-- resume：匹配事件的 payload。
-- 常见坑：filter 过严永远不醒；无 listen 后端时 session 会失败或挂死。
-- tabMachine 对照：近似事件等待节点（本库无 Tab DSL）。
--
-- 仓库根：lua examples/fx_api/wait_event.lua

package.path = "src/?.lua;examples/fx_api/?.lua;" .. package.path

local C = require("_common")
local Cont, fx = C.Cont, C.fx

local M = {}

function M.run(opts)
  opts = opts or {}
  C.quiet = not not opts.quiet

  C.section("fx.wait_event + filter（dmg>=10）")
  local sim = C.new_sim()
  local got
  local pipe = fx.wait_event("hit", function(p)
    return p and p.dmg and p.dmg >= 10
  end) >> function(payload)
    got = payload
    return Cont.unit(payload.dmg)
  end

  local flow = sim:start_flow(nil, pipe)
  C.need(not flow.done, "should park on wait_event")
  sim:emit("hit", { dmg = 3 }) -- 过滤不匹配
  C.need(not flow.done, "dmg=3 should not wake")
  sim:emit("hit", { dmg = 12 })
  C.need(flow.done and flow.result.ok and flow.result.value == 12, "dmg=12 wakes")
  C.need(got and got.dmg == 12, "payload preserved")
  C.log("  payload.dmg=%s", tostring(got.dmg))

  if not C.quiet then C.ok("wait_event") end
  return true
end

if arg and arg[0] and arg[0]:match("wait_event%.lua$") then
  local quiet = arg[1] == "test" or arg[1] == "--quiet"
  M.run({ quiet = quiet })
  if quiet then C.ok("wait_event") end
end

return M
