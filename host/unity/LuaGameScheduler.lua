-- LuaGameScheduler.lua — Unity / Mock 用的 Scheduler 薄适配
--
-- 期望注入的 host（由 C# UnityGameScheduler 或 MockUnityHost 提供）：
--   host.now()                    → number          -- scaled 游戏时间
--   host.schedule(delay, cb)      → id / handle     -- scaled；cancel 时原样传回
--   host.cancel(id)               → nil
--   host.schedule_real?(delay,cb) → id / handle     -- 可选：墙钟 / unscaled（fx.wait_real）
--
-- 产出对象满足 src/scheduler.lua 鸭子接口，可直接作为
--   fx.run(..., { scheduler = sched })
--   fx_sched.start_session(..., { scheduler = sched })
-- 若 host 提供 schedule_real，adapt 结果也会暴露 sched.schedule_real（供 wait_real）。
--
-- ── xLua 侧典型接线（与 UnityGameScheduler.InjectIntoLua / FxUnityBootstrap 配合）──
--
--   -- C# 已把三个闭包塞进全局 UnityHost，或 Push 了 CS.UnityGameScheduler.Instance
--   local host = rawget(_G, "UnityHost")
--   -- 或手工包一层（xLua 调 C#）：
--   -- local U = CS.UnityGameScheduler.Instance
--   -- local host = {
--   --   now = function() return U:Now() end,
--   --   schedule = function(delay, cb) return U:ScheduleLua(delay, cb) end,
--   --   cancel = function(id) U:Cancel(id) end,
--   --   -- 可选墙钟：
--   --   schedule_real = function(delay, cb) return U:ScheduleLuaReal(delay, cb) end,
--   -- }
--   local sched = require("LuaGameScheduler").adapt(host)
--   local fx = require("fx")
--   fx.run(my_flow, nil, { scheduler = sched })
--
-- 更省事：用 FxUnityBootstrap.bootstrap(host) 一次拿到 .scheduler / .run。
--
-- 与 0.2.x-eng 工程 API 配合（本文件只做时间后端；下列由业务 / GameSim 层调用）：
--   fx.register / fx.unregister     — 全局效果注册；未知 kind → Failed
--   fx.bind_entity(flow, entity)    — 实体 OnDestroy 时 cancel（见 fx_flow）
--   fx.with_resource / Cont.bracket — 资源获取-使用-释放
--   opts.trace / fx.set_tracer      — 轻量追踪（默认关）
--   fx.wait_until / FrameScheduler  — 每帧 poll；弱 timer 时用 tick(dt) 后端
--   fx.wait_real                    — 仅当 schedule_real 或 opts.allow_real_time
--   GameSim:start_flow(entity, ma)  — 参考宿主；Unity 侧同样 pattern

local M = {}

local function dual(self, a, b, c)
  if a == self then
    return b, c
  end
  return a, b
end

--- adapt(host) → scheduler
-- host 可为 table（含 now/schedule/cancel）或已是本适配产物（原样返回）。
-- 方法调用支持 sched.now() / sched:now() 两种写法（xLua 绑定常混用）。
function M.adapt(host)
  assert(type(host) == "table", "LuaGameScheduler.adapt: host table required")

  if type(host.now) == "function"
    and type(host.schedule) == "function"
    and type(host.cancel) == "function"
    and host.__lua_game_scheduler
  then
    return host
  end

  assert(type(host.now) == "function", "host.now required")
  assert(type(host.schedule) == "function", "host.schedule required")
  assert(type(host.cancel) == "function", "host.cancel required")

  local sched = { __lua_game_scheduler = true }

  function sched.now(...)
    local _ = dual(sched, ...)
    return host.now()
  end

  --- schedule(delay, cb) → handle { id, cancelled }
  -- 包装 cb：若已 cancel 则忽略（防迟到回调）。
  function sched.schedule(...)
    local delay, cb = dual(sched, ...)
    assert(type(cb) == "function", "LuaGameScheduler.schedule: cb must be function")
    delay = delay or 0
    local handle = { cancelled = false }
    local id = host.schedule(delay, function()
      if handle.cancelled then
        return
      end
      cb()
    end)
    handle.id = id
    return handle
  end

  function sched.cancel(...)
    local handle = dual(sched, ...)
    if handle == nil then
      return
    end
    handle.cancelled = true
    if handle.id ~= nil then
      host.cancel(handle.id)
    end
  end

  -- 可选：墙钟调度（fx.wait_real）。无则 session 在未开 allow_real_time 时 Failed。
  if type(host.schedule_real) == "function" then
    function sched.schedule_real(...)
      local delay, cb = dual(sched, ...)
      assert(type(cb) == "function", "LuaGameScheduler.schedule_real: cb must be function")
      delay = delay or 0
      local handle = { cancelled = false }
      local id = host.schedule_real(delay, function()
        if handle.cancelled then
          return
        end
        cb()
      end)
      handle.id = id
      return handle
    end
  end

  return sched
end

return M
