-- LuaGameScheduler.lua — Unity / Mock 用的 Scheduler 薄适配
--
-- 期望注入的 host（由 C# 或 MockUnityHost 提供）：
--   host.now()                 → number
--   host.schedule(delay, cb)   → id   （或 handle；cancel 时原样传回）
--   host.cancel(id)            → nil
--
-- 产出对象满足 src/scheduler.lua 鸭子接口，可直接作为
--   fx.run(..., { scheduler = sched })
--   fx_sched.start_session(..., { scheduler = sched })
--
-- 用法：
--   local LuaGameScheduler = require("LuaGameScheduler")
--   local sched = LuaGameScheduler.adapt(host)
--
-- 与 0.2.0-eng 工程 API 配合（本文件只做时间后端；下列由业务 / GameSim 层调用）：
--   fx.register / fx.unregister     — 全局效果注册；未知 kind → Failed
--   fx.bind_entity(flow, entity)  — 实体 OnDestroy 时 cancel（见 fx_flow）
--   fx.with_resource / Cont.bracket — 资源获取-使用-释放
--   opts.trace / fx.set_tracer      — 轻量追踪（默认关）
--   GameSim:start_flow(entity, ma)  — 参考宿主；Unity 侧同样 pattern

local M = {}

local function dual(self, a, b, c)
  if a == self then
    return b, c
  end
  return a, b
end

--- adapt(host) → scheduler
-- host 可为 table（含 now/schedule/cancel）或已是 scheduler（原样返回）。
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

  return sched
end

return M
