-- fx_sched_drive.lua — drive_until_block 薄分派 + 共享 wait/join 辅助
-- kind 实现见 fx_sched_drive_{wait,fork,lane,proxy,chan,registry}.lua
local Coro = require("coro")

local Mod = {}

function Mod.install(S)

  ------------------------------------------------------------
  -- 共享辅助：timer 登记 / 已结束子 → join 方
  ------------------------------------------------------------

  function S.arm_scheduler_timer(task, opts, secs, schedule_fn, on_fire_kind)
    local flag = { cancelled = false }
    local handle = schedule_fn(secs, function()
      S.when_flow_active(opts, function()
        if flag.cancelled then
          return
        end
        if task.finished or not task.waiting then
          return
        end
        task.waiting = false
        task.timer_handle = nil
        task._timer_flag = nil
        if opts.verbose_wait then
          print(string.format("[fx.session] task#%d %s done (scheduler)", task.id, on_fire_kind or "wait"))
        end
        if on_fire_kind == "wait_real" then
          S.emit_trace(opts, { type = "resume", task_id = task.id, kind = "wait_real" })
        end
        task.answer = Coro.resume(task.answer, true)
        if type(opts._pump) == "function" then
          opts._pump()
        end
      end)
    end)
    task.timer_handle = handle
    task._timer_flag = flag
    task.waiting = true
  end

  function S.apply_finished_child_to_waiter(task, child, want_cancel, nursery)
    if Coro.isDone(child.answer) then
      task.answer = Coro.resume(task.answer, child.result)
      if want_cancel then
        S.cancel_fork_siblings(nursery, { [child.id] = true }, task.id, "cancelled")
      end
      return nil
    elseif Coro.isFailed(child.answer) then
      task.answer = Coro.Failed(child.answer.error)
      return "failed"
    elseif Coro.isAborted(child.answer) then
      task.answer = Coro.Aborted(child.answer.reason)
      return "aborted"
    elseif Coro.isStopped(child.answer) then
      task.answer = Coro.Stopped(child.answer.reason)
      return "stopped"
    end
    error("fx_sched: child finished with unexpected tag")
  end

  -- 已结束 → apply；否则 park 到 child.joiners（lane/proxy/fork join 共用）
  -- extra?: { proxy_stop_host = bool }
  function S.join_finished_or_park(nursery, task, child, want_cancel, extra)
    if child.finished then
      return S.apply_finished_child_to_waiter(task, child, want_cancel, nursery)
    end
    task.parked = "join"
    task.join_target = child.id
    task.join_cancel_siblings = want_cancel
    if extra and extra.proxy_stop_host then
      task.proxy_stop_host = true
    end
    child.joiners[#child.joiners + 1] = task.id
    return "parked"
  end

  ------------------------------------------------------------
  -- kind → handler 表（各子模块往 S.drive_handlers 登记）
  ------------------------------------------------------------
  S.drive_handlers = {}
  require("fx_sched_drive_wait").install(S)
  require("fx_sched_drive_fork").install(S)
  require("fx_sched_drive_lane").install(S)
  require("fx_sched_drive_proxy").install(S)
  require("fx_sched_drive_chan").install(S)
  require("fx_sched_drive_registry").install(S)

  ------------------------------------------------------------
  -- 薄分派：取消检测 → 查表 → 终态
  ------------------------------------------------------------
  function S.drive_until_block(nursery, task)
    local kind_handlers = S.drive_handlers

    while Coro.isYielded(task.answer) do
      if S.is_cancelled(nursery.opts.cancel) then
        S.clear_task_waits(task)
        task.answer = S.force_stop_task_answer(task.answer, "cancelled")
        return "stopped"
      end
      local req = task.answer.value
      assert(type(req) == "table" and req.kind ~= nil,
        "fx_sched: expected yield payload table with .kind")

      local h = kind_handlers[req.kind] or kind_handlers.__registry
      local st = h(nursery, task, req)
      if st then
        return st
      end
    end

    if Coro.isDone(task.answer) then
      return "done"
    elseif Coro.isAborted(task.answer) then
      return "aborted"
    elseif Coro.isStopped(task.answer) then
      return "stopped"
    elseif Coro.isFailed(task.answer) then
      return "failed"
    end
    error("fx_sched: unexpected answer tag=" .. tostring(task.answer and task.answer.tag), 2)
  end

end

return Mod
