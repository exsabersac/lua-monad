#!/usr/bin/env lua
-- main.lua — 「地牢突袭」可执行入口
-- 在仓库根目录：lua examples/dungeon_raid/main.lua
--
-- 无参数：叙事通关；传 test → 安静自检模式。

package.path = "src/?.lua;examples/dungeon_raid/?.lua;" .. package.path

local DungeonRaid = require("dungeon")

local mode = arg and arg[1]
local opts = {}

if mode == "test" or mode == "--test" then
  opts.quiet = true
  opts.assert = true
  opts.verbose = false
  print("[模拟 0.00s] 地牢突袭 · 自检模式")
else
  opts.quiet = false
  opts.assert = true -- 通关跑完也断言，确保 showcase 不漂
  print("[模拟 0.00s] ========================================")
  print("[模拟 0.00s]   地牢突袭 Dungeon Raid")
  print("[模拟 0.00s]   Cont + withEnv + fx + GameSim 综合演示")
  print("[模拟 0.00s] ========================================")
  print("")
end

local ok, result = pcall(DungeonRaid.run, opts)
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
slog("  剩余 HP: %d", result.hp or -1)
slog("  清空房间: %d", result.rooms or 0)
slog("  游戏时间: %.2fs", result.game_time or 0)
slog("  Boss 路径: %s", tostring(result.boss_path))
slog("  校验 pause=%s finally=%s chests=%s",
  tostring(result.checks.pause_deferred),
  tostring(result.checks.mob_finally),
  tostring(result.checks.chests_parallel))
slog("----------------------")

if result.victory and result.ok then
  slog("地牢突袭 OK — 胜利通关")
  os.exit(0)
else
  io.stderr:write("地牢突袭未胜利\n")
  os.exit(1)
end
