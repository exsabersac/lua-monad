-- _common.lua — fx_api 示例共用：GameSim / VirtualClock、日志、断言
-- 游戏等待一律走 GameSim tick（或 VirtualClock.advance），禁止对游戏 wait 用墙钟 busy_wait。

local Cont = require("cont")
local fx = require("fx")
local GameSim = require("game_sim")
local Scheduler = require("scheduler")

local M = {
  quiet = false,
  Cont = Cont,
  fx = fx,
  GameSim = GameSim,
  Scheduler = Scheduler,
}

--- 非 quiet 时打印
function M.log(fmt, ...)
  if M.quiet then
    return
  end
  if select("#", ...) > 0 then
    print(string.format(fmt, ...))
  else
    print(tostring(fmt))
  end
end

--- 章节标题
function M.section(title)
  M.log("=== %s ===", title)
end

--- 成功行（始终打印，便于 smoke 扫 OK）
function M.ok(name)
  print(string.format("fx_api/%s OK", name))
end

--- 新建 GameSim（默认 dt=0.05）
function M.new_sim(opts)
  opts = opts or {}
  return GameSim.new({ dt = opts.dt or 0.05 })
end

--- sim:run(ma)；返回 result, sim
function M.run_sim(ma, handlers, opts)
  opts = opts or {}
  local sim = opts.sim or M.new_sim(opts)
  local r = sim:run(ma, handlers, opts)
  return r, sim
end

--- VirtualClock + start_session；advance 直到 done 或 max 推进
-- fn(clock, Sched) 应返回 flow；本函数负责 advance
function M.run_vc(ma, handlers, opts)
  opts = opts or {}
  local Sched = require("fx_sched")
  local clock = Scheduler.VirtualClock()
  local so = {}
  for k, v in pairs(opts) do
    so[k] = v
  end
  so.scheduler = clock
  local flow = Sched.start_session(ma, handlers or {}, so)
  local step = opts.step or 0.05
  local max_t = opts.max_t or 10
  local guard = 0
  while not flow.done and clock.now() < max_t and guard < 100000 do
    clock.advance(step)
    guard = guard + 1
  end
  return flow.result, clock, flow
end

--- 小断言：失败则 error（让 main 捕获）
function M.need(cond, msg)
  if not cond then
    error(msg or "assertion failed", 2)
  end
end

return M
