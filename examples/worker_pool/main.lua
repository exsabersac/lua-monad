#!/usr/bin/env lua
-- main.lua — 「工人池」可执行入口
-- 在仓库根目录：lua examples/worker_pool/main.lua

package.path = "src/?.lua;examples/worker_pool/?.lua;" .. package.path

local WorkerPool = require("workers")

local mode = arg and arg[1]
local opts = {}

if mode == "test" or mode == "--test" then
  opts.quiet = true
  opts.assert = true
  opts.verbose = false
  print("[模拟 0.00s] 工人池 · 自检模式")
else
  opts.quiet = false
  opts.assert = true
  print("[模拟 0.00s] ========================================")
  print("[模拟 0.00s]   工人池 Worker Pool")
  print("[模拟 0.00s]   chan 背压 / map_parallel / supervise / lanes")
  print("[模拟 0.00s] ========================================")
  print("")
end

local ok, result = pcall(WorkerPool.run, opts)
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
slog("  产出/结果: %d / %d", result.produced or -1, result.results or -1)
slog("  游戏时间: %.2fs", result.game_time or 0)
local C = result.checks or {}
local S = result.stats or {}
slog("  校验 backpressure=%s flaky=%s/%s map_parallel=%s",
  tostring(C.backpressure), tostring(C.flaky_failed),
  tostring(C.flaky_recovered), tostring(C.map_parallel))
slog("  统计 blocked_sends≈%s max_buf=%s",
  tostring(S.blocked_sends), tostring(S.max_buf))
slog("----------------------")

if result.victory and result.ok then
  slog("工人池 OK — 全部完成")
  os.exit(0)
else
  io.stderr:write("工人池未胜利\n")
  os.exit(1)
end
