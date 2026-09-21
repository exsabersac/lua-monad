#!/usr/bin/env lua
-- main.lua — 「护卫任务」可执行入口
-- 在仓库根目录：lua examples/escort_mission/main.lua
--
-- 无参数：叙事通关；传 test → 安静自检模式。

package.path = "src/?.lua;examples/escort_mission/?.lua;" .. package.path

local EscortMission = require("escort")

local mode = arg and arg[1]
local opts = {}

if mode == "test" or mode == "--test" then
  opts.quiet = true
  opts.assert = true
  opts.verbose = false
  print("[模拟 0.00s] 护卫任务 · 自检模式")
else
  opts.quiet = false
  opts.assert = true
  print("[模拟 0.00s] ========================================")
  print("[模拟 0.00s]   护卫任务 Escort Mission")
  print("[模拟 0.00s]   lanes / proxy / chan / supervise / timeout")
  print("[模拟 0.00s] ========================================")
  print("")
end

local ok, result = pcall(EscortMission.run, opts)
if not ok then
  io.stderr:write("运行失败: " .. tostring(result) .. "\n")
  os.exit(1)
end

local function slog(fmt, ...)
  local gt = (result and result.game_time) or 0
  local msg = select("#", ...) > 0 and string.format(fmt, ...) or tostring(fmt)
  print(string.format("[模拟 %.2fs] %s", gt, msg))
end

print("")
slog("-------- 结算 --------")
slog("  胜利: %s", tostring(result.victory))
slog("  玩家 HP: %d", result.hp or -1)
slog("  商队 HP: %d", result.escort_hp or -1)
slog("  抵达检查点: %d", result.arrived or 0)
slog("  游戏时间: %.2fs", result.game_time or 0)
local C = result.checks or {}
slog("  校验 pause=%s finally=%s lanes=%s proxy=%s",
  tostring(C.pause_deferred), tostring(C.enemy_finally),
  tostring(C.lanes_used), tostring(C.hud_proxy))
slog("  校验 chan_cp=%s chan_alert=%s supervise=%s/%s rescue=%s",
  tostring(C.checkpoint_chan), tostring(C.alert_chan),
  tostring(C.ambush_supervise_failed), tostring(C.ambush_supervised),
  tostring(C.rescue_ok))
slog("----------------------")

if result.victory and result.ok then
  slog("护卫任务 OK — 胜利通关")
  os.exit(0)
else
  io.stderr:write("护卫任务未胜利\n")
  os.exit(1)
end
