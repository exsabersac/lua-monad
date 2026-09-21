-- scheduler.lua — 游戏时间 Scheduler 接口与虚拟时钟
--
-- 约定（对接工程 / GameSim）：
--   now()              → number   当前游戏时间（逻辑秒）
--   schedule(delay,cb) → handle   再过 delay 秒后回调；pause 时时间不推进则延后
--   cancel(handle)     → 取消尚未触发的回调；迟到回调必须忽略
--
-- Session（fx_sched）只依赖本接口；不直接碰引擎定时器。
-- 本文件提供 VirtualClock 供单测 / 无 GameSim 时驱动。

local M = {}

------------------------------------------------------------
-- 接口检查
------------------------------------------------------------

--- 是否像 Scheduler（duck typing）
function M.is_scheduler(s)
  return type(s) == "table"
    and type(s.now) == "function"
    and type(s.schedule) == "function"
    and type(s.cancel) == "function"
end

------------------------------------------------------------
-- VirtualClock：可 advance 的游戏时间后端（单测友好）
------------------------------------------------------------

--- VirtualClock.new(opts?) → scheduler
-- opts.auto_sort：到期回调按 due 排序（默认 true）
function M.VirtualClock(opts)
  opts = opts or {}
  local auto_sort = opts.auto_sort ~= false
  local time = 0
  local next_id = 0
  local timers = {} -- id → { due, cb, handle }

  local clock = {}

  function clock.now()
    return time
  end

  --- schedule(delay, cb) → handle；handle.cancelled 供迟到回调检查
  function clock.schedule(delay, cb)
    assert(type(cb) == "function", "VirtualClock.schedule: cb must be function")
    delay = delay or 0
    next_id = next_id + 1
    local id = next_id
    local handle = { id = id, cancelled = false }
    timers[id] = {
      due = time + delay,
      cb = cb,
      handle = handle,
    }
    return handle
  end

  function clock.cancel(handle)
    if handle == nil then
      return
    end
    handle.cancelled = true
    if handle.id and timers[handle.id] then
      timers[handle.id] = nil
    end
  end

  --- advance(dt)：推进游戏时间并触发到期回调（同一 Lua「线程」）
  function clock.advance(dt)
    dt = dt or 0
    if dt < 0 then
      dt = 0
    end
    time = time + dt
    local due = {}
    for id, t in pairs(timers) do
      if not t.handle.cancelled and t.due <= time + 1e-12 then
        due[#due + 1] = { id = id, t = t }
      end
    end
    if auto_sort then
      table.sort(due, function(a, b)
        if a.t.due == b.t.due then
          return a.id < b.id
        end
        return a.t.due < b.t.due
      end)
    end
    for _, item in ipairs(due) do
      timers[item.id] = nil
      if not item.t.handle.cancelled then
        item.t.cb()
      end
    end
  end

  --- 是否还有未触发定时器
  function clock.pending_count()
    local n = 0
    for _ in pairs(timers) do
      n = n + 1
    end
    return n
  end

  return clock
end

M.new_virtual = M.VirtualClock -- 别名

return M
