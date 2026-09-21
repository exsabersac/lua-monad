#!/usr/bin/env lua
-- wait.lua — Core · fx.wait：游戏时间延迟（非墙钟）
--
-- 用途：在 Cont 管道里「睡」N 秒（逻辑/游戏时间），resume 值为 true。
-- 参数：seconds（number，默认 0）；yield kind="wait"。
-- 与 Core/Sugar：Core 原语；游戏逻辑请配合 GameSim / VirtualClock，勿用 wait_real。
-- 常见坑：无 scheduler 时默认 handler 会 busy_wait（墙钟）——工程务必注入 opts.scheduler。
-- tabMachine 对照：近似 delay / wait 定时器节点（无 Tab DSL）。
--
-- 仓库根：lua examples/fx_api/wait.lua

package.path = "src/?.lua;examples/fx_api/?.lua;" .. package.path

local C = require("_common")
local Cont, fx = C.Cont, C.fx

local M = {}

function M.run(opts)
  opts = opts or {}
  C.quiet = not not opts.quiet

  C.section("fx.wait 游戏时间 0.3s（GameSim tick）")
  C.log("  before wait；由 sim:tick 推进游戏时间")
  -- seconds → Cont Answer boolean；resume 恒为 true
  local pipe = fx.wait(0.3) >> function(ok)
    C.log("  resumed ok=%s", tostring(ok))
    return Cont.unit(ok)
  end

  local wall0 = os.clock()
  local r, sim = C.run_sim(pipe)
  local wall = os.clock() - wall0

  C.need(r.ok and r.value == true, "wait should resume true")
  C.need(sim:now() >= 0.3 - 1e-9 and sim:now() < 0.45,
    "game time ≈ 0.3, got " .. tostring(sim:now()))
  -- 无墙钟 busy：墙钟应远小于 0.3
  C.need(wall < 0.08, "wall should be tiny, got " .. tostring(wall))
  C.log("  game_time=%.2f wall=%.4fs", sim:now(), wall)

  if not C.quiet then C.ok("wait") end
  return true
end

if arg and arg[0] and arg[0]:match("wait%.lua$") then
  local quiet = arg[1] == "test" or arg[1] == "--quiet"
  M.run({ quiet = quiet })
  if quiet then C.ok("wait") end
end

return M
