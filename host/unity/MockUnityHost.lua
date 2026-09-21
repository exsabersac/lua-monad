-- MockUnityHost.lua — 无 Unity 时模拟 host.now/schedule/cancel
--
-- 便于本地演示 LuaGameScheduler 适配形状（仓库根目录）：
--   lua5.3 -e 'package.path="src/?.lua;host/unity/?.lua;"..package.path
--              require("MockUnityHost").demo()'
--
-- 两种后端：
--   with_virtual()  → VirtualClock（需手动 pump/advance）
--   with_gamesim()  → GameSim（可 tick；兼作更完整参考）

local M = {}

--- with_virtual(opts?) → host, pump, clock
-- host 满足 LuaGameScheduler 注入约定；pump(dt) 推进虚拟时间。
function M.with_virtual(opts)
  local Scheduler = require("scheduler")
  local clock = Scheduler.VirtualClock(opts)
  local host = {}

  function host.now()
    return clock.now()
  end

  function host.schedule(delay, cb)
    return clock.schedule(delay, cb)
  end

  function host.cancel(id_or_handle)
    clock.cancel(id_or_handle)
  end

  local function pump(dt)
    clock.advance(dt)
  end

  return host, pump, clock
end

--- with_gamesim(opts?) → host, sim
-- 把 GameSim 的 Scheduler 面暴露成 host；驱动用 sim:tick / sim:run。
function M.with_gamesim(opts)
  local GameSim = require("game_sim")
  local sim = GameSim.new(opts)
  local host = {}

  function host.now()
    return sim.now()
  end

  function host.schedule(delay, cb)
    return sim.schedule(delay, cb)
  end

  function host.cancel(id_or_handle)
    sim.cancel(id_or_handle)
  end

  return host, sim
end

--- demo()：确认适配可用（请已设置 package.path 含 src/ 与 host/unity/）
function M.demo()
  local LuaGameScheduler = require("LuaGameScheduler")
  local host, pump = M.with_virtual()
  local S = LuaGameScheduler.adapt(host)
  local done = false
  S.schedule(0.3, function()
    done = true
  end)
  assert(S.now() == 0)
  pump(0.2)
  assert(not done)
  pump(0.1)
  assert(done)
  -- cancel + late ignore
  local fired = false
  local h = S.schedule(1.0, function()
    fired = true
  end)
  S.cancel(h)
  pump(2.0)
  assert(not fired)
  print("MockUnityHost.demo ok @", S.now())
end

return M
