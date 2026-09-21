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
  print("地牢突袭 · 自检模式")
else
  opts.quiet = false
  opts.assert = true -- 通关跑完也断言，确保 showcase 不漂
  print("========================================")
  print("  地牢突袭 Dungeon Raid")
  print("  Cont + withEnv + fx + GameSim 综合演示")
  print("========================================")
  print("")
end

local ok, result = pcall(DungeonRaid.run, opts)
if not ok then
  io.stderr:write("运行失败: " .. tostring(result) .. "\n")
  os.exit(1)
end

print("")
print("-------- 结算 --------")
print(string.format("  胜利: %s", tostring(result.victory)))
print(string.format("  剩余 HP: %d", result.hp or -1))
print(string.format("  清空房间: %d", result.rooms or 0))
print(string.format("  游戏时间: %.2fs", result.game_time or 0))
print(string.format("  Boss 路径: %s", tostring(result.boss_path)))
print(string.format("  校验 pause=%s finally=%s chests=%s",
  tostring(result.checks.pause_deferred),
  tostring(result.checks.mob_finally),
  tostring(result.checks.chests_parallel)))
print("----------------------")

if result.victory and result.ok then
  print("地牢突袭 OK — 胜利通关")
  os.exit(0)
else
  io.stderr:write("地牢突袭未胜利\n")
  os.exit(1)
end
