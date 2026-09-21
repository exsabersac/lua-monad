-- fx_sched_supervise.lua — supervise 启停 / backoff / 重启
local Coro = require("coro")
local Cont = require("cont")

local Mod = {}

function Mod.install(S)

function S.start_supervise(nursery, parent, req)
  local ma = req.task
  assert(ma ~= nil, "fx_sched: supervise requires .task")
  local max_restarts = req.max_restarts
  if max_restarts == nil then
    max_restarts = 3
  end
  local backoff = req.backoff or 0
  local group = {
    parent_id = parent.id,
    mode = "supervise",
    child_ids = {},
    values = {},
    done_count = 0,
    n = 0,
    settled = false,
    ma = ma,
    max_restarts = max_restarts,
    backoff = backoff,
    restart_if = req.restart_if,
    on_fail = req.on_fail,
    restart_on_stop = not not req.restart_on_stop,
    restarts = 0,
    current_child_id = nil,
  }
  parent.parked = "group"
  parent.waiting_group = group
  S.spawn_supervise_child(nursery, group)
  return "parked"
end

function S.spawn_supervise_child(nursery, group)
  if group.settled then
    return
  end
  local parent = nursery.tasks[group.parent_id]
  if not parent or parent.finished then
    return
  end
  local opts = nursery.opts or {}
  if S.is_cancelled(opts.cancel) then
    S.settle_group(nursery, group, "stopped", {
      id = 0,
      group_pos = 0,
      answer = Coro.Stopped("cancelled"),
    })
    return
  end
  local child = S.alloc_task(nursery, group.ma)
  child.group_ref = group
  child.group_pos = #group.child_ids + 1
  child.parent_id = parent.id
  S.inherit_deadline(child, parent)
  group.child_ids[#group.child_ids + 1] = child.id
  group.current_child_id = child.id
  group.n = #group.child_ids
  S.emit_trace(opts, {
    type = "supervise_start",
    task_id = parent.id,
    child_id = child.id,
    attempt = group.restarts + 1,
    restarts = group.restarts,
  })
end

function S.supervise_should_restart(group, child, status)
  if group.restarts >= group.max_restarts then
    return false
  end
  if status == "failed" then
    local err = child.answer and child.answer.error
    if type(group.restart_if) == "function" then
      local ok, allow = pcall(group.restart_if, err)
      if not ok or not allow then
        return false
      end
    end
    if type(group.on_fail) == "function" then
      local ok, ret = pcall(group.on_fail, err)
      if ok and ret == false then
        return false
      end
    end
    return true
  end
  if status == "stopped" and group.restart_on_stop then
    local reason = child.answer and child.answer.reason
    if reason == "cancelled" then
      return false
    end
    return true
  end
  return false
end

function S.schedule_supervise_restart(nursery, group)
  local parent = nursery.tasks[group.parent_id]
  if not parent or parent.finished or group.settled then
    return
  end
  local opts = nursery.opts or {}
  local backoff = group.backoff or 0

  if backoff <= 0 then
    if S.is_cancelled(opts.cancel) then
      S.settle_group(nursery, group, "stopped", {
        id = 0,
        group_pos = 0,
        answer = Coro.Stopped("cancelled"),
      })
      return
    end
    S.spawn_supervise_child(nursery, group)
    return
  end

  -- backoff：用 wait 任务（有 scheduler 时走游戏时间 schedule；否则时间轮/busy）
  -- 必须是 nursery 任务，否则 pump 会把「仅 parked 的 supervise」当成 deadlock
  local timer_ma = Coro.yield({ kind = "wait", seconds = backoff }) >> function(_)
    return Cont.unit(true)
  end
  local timer = S.alloc_task(nursery, timer_ma)
  timer.parent_id = parent.id
  timer._supervise_backoff_group = group
  group._backoff_task_id = timer.id
end

function S.try_supervise_after_child(nursery, group, child, status)
  local parent = nursery.tasks[group.parent_id]
  if not parent or parent.finished then
    return
  end
  if status == "done" then
    S.settle_group(nursery, group, "done", child)
    return
  end
  if S.supervise_should_restart(group, child, status) then
    group.restarts = group.restarts + 1
    S.emit_trace(nursery.opts, {
      type = "supervise_restart",
      task_id = parent.id,
      child_id = child.id,
      restarts = group.restarts,
      max_restarts = group.max_restarts,
      status = status,
      error = child.answer and child.answer.error,
      reason = child.answer and child.answer.reason,
    })
    S.schedule_supervise_restart(nursery, group)
    return
  end
  S.settle_group(nursery, group, status, child)
end

end

return Mod
