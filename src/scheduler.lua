-- scheduler.lua — 游戏时间 Scheduler 接口与虚拟时钟
--
-- 约定（对接工程 / GameSim / FrameScheduler）：
--   now()              → number   当前游戏时间（逻辑秒）
--   schedule(delay,cb) → handle   再过 delay 秒后回调；pause 时时间不推进则延后
--   cancel(handle)     → 取消尚未触发的回调；迟到回调必须忽略
-- 可选（wait_until）：
--   schedule_poll(pred, cb, opts?) → handle  每 tick/interval 调 pred；真值则 cb
--
-- Session（fx_sched）只依赖本接口；不直接碰引擎定时器。
-- VirtualClock：单测用 advance(dt)；无 poll。
-- FrameScheduler：tick(dt) 推进时间 + 到期 timer + wait_until polls；
--   适合引擎有 update(dt) 但定时器弱的场景（亦可直接用 GameSim）。

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

------------------------------------------------------------
-- FrameScheduler：tick(dt) 驱动的游戏时间后端
-- 适用：引擎有 update(dt) / FixedUpdate，但定时器弱或不想依赖引擎 timer。
-- 能力：now / schedule / cancel / tick(dt)
--   tick 推进时间、触发到期 timer，并 poll 登记的 wait_until 谓词。
-- 与 VirtualClock 区别：显式 tick 命名 + schedule_poll（每帧谓词）。
-- GameSim 亦提供同名 schedule_poll，可作等价宿主。
------------------------------------------------------------

--- FrameScheduler(opts?) → scheduler
-- opts.auto_sort：到期 timer 按 due 排序（默认 true）
function M.FrameScheduler(opts)
  opts = opts or {}
  local auto_sort = opts.auto_sort ~= false
  local time = 0
  local next_id = 0
  local timers = {} -- id → { due, cb, handle }
  local polls = {}  -- id → { pred, cb, handle, interval, next_at, on_error }

  local clock = { __frame_scheduler = true }

  function clock.now()
    return time
  end

  function clock.schedule(delay, cb)
    assert(type(cb) == "function", "FrameScheduler.schedule: cb must be function")
    delay = delay or 0
    next_id = next_id + 1
    local id = next_id
    local handle = { id = id, cancelled = false, kind = "timer" }
    timers[id] = {
      due = time + delay,
      cb = cb,
      handle = handle,
    }
    return handle
  end

  --- schedule_poll(pred, cb, poll_opts?) → handle
  -- 每 tick（或 interval 间隔）调用 pred()；真值则 cb(result) 并移除。
  -- poll_opts.interval：两次 poll 最小间隔（游戏秒，默认 0 = 每 tick）
  -- poll_opts.on_error(err)：pred 抛错时调用（默认 rethrow）
  function clock.schedule_poll(pred, cb, poll_opts)
    assert(type(pred) == "function", "FrameScheduler.schedule_poll: pred must be function")
    assert(type(cb) == "function", "FrameScheduler.schedule_poll: cb must be function")
    poll_opts = poll_opts or {}
    local interval = poll_opts.interval or 0
    assert(type(interval) == "number" and interval >= 0,
      "FrameScheduler.schedule_poll: interval must be >= 0")
    next_id = next_id + 1
    local id = next_id
    local handle = { id = id, cancelled = false, kind = "poll" }
    polls[id] = {
      pred = pred,
      cb = cb,
      handle = handle,
      interval = interval,
      next_at = time,
      on_error = poll_opts.on_error,
    }
    return handle
  end

  function clock.cancel(handle)
    if handle == nil then
      return
    end
    handle.cancelled = true
    if handle.id then
      timers[handle.id] = nil
      polls[handle.id] = nil
    end
  end

  local function fire_due_timers()
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

  local function run_polls()
    local ids = {}
    for id, _ in pairs(polls) do
      ids[#ids + 1] = id
    end
    table.sort(ids)
    for _, id in ipairs(ids) do
      local p = polls[id]
      if p and not p.handle.cancelled and time + 1e-12 >= p.next_at then
        local ok, result = pcall(p.pred)
        if not ok then
          polls[id] = nil
          p.handle.cancelled = true
          if type(p.on_error) == "function" then
            p.on_error(result)
          else
            error(result)
          end
        elseif result then
          polls[id] = nil
          p.handle.cancelled = true
          p.cb(result)
        else
          p.next_at = time + p.interval
        end
      end
    end
  end

  --- tick(dt)：推进游戏时间 → 到期 timer → wait_until polls
  function clock.tick(dt)
    dt = dt or 0
    if dt < 0 then
      dt = 0
    end
    time = time + dt
    fire_due_timers()
    run_polls()
  end

  --- advance(dt)：与 tick 同义（兼容 VirtualClock 习惯）
  clock.advance = clock.tick

  function clock.pending_count()
    local n = 0
    for _ in pairs(timers) do
      n = n + 1
    end
    for _ in pairs(polls) do
      n = n + 1
    end
    return n
  end

  function clock.pending_timers()
    local n = 0
    for _ in pairs(timers) do
      n = n + 1
    end
    return n
  end

  function clock.pending_polls()
    local n = 0
    for _ in pairs(polls) do
      n = n + 1
    end
    return n
  end

  return clock
end

M.new_frame = M.FrameScheduler -- 别名

return M
