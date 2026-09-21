-- fx_sched_drive_fork.lua — fork / join / when_* / supervise / with_timeout 分派
local Coro = require("coro")

local Mod = {}

function Mod.install(S)
  local H = S.drive_handlers

  function H.when_all(nursery, task, req)
    local opts = nursery.opts
    S.emit_trace(opts, { type = "yield", task_id = task.id, kind = req.kind })
    local st = S.start_group(nursery, task, req, "all")
    if st == "failed" then
      return "failed"
    end
    if st == "parked" then
      return "parked"
    end
    -- continued（空 all）：继续循环
  end

  function H.when_any(nursery, task, req)
    local opts = nursery.opts
    S.emit_trace(opts, { type = "yield", task_id = task.id, kind = req.kind })
    local st = S.start_group(nursery, task, req, "any")
    if st == "failed" then
      return "failed"
    end
    if st == "parked" then
      return "parked"
    end
  end

  function H.with_timeout(nursery, task, req)
    local st = S.start_timeout_race(nursery, task, req)
    if st == "parked" then
      return "parked"
    end
  end

  function H.supervise(nursery, task, req)
    local opts = nursery.opts
    S.emit_trace(opts, { type = "yield", task_id = task.id, kind = "supervise" })
    local st = S.start_supervise(nursery, task, req)
    if st == "parked" then
      return "parked"
    end
  end

  function H.fork(nursery, task, req)
    local opts = nursery.opts
    local ma = req.task
    assert(ma ~= nil, "fx_sched: fork requires .task")
    local child = S.alloc_task(nursery, ma)
    child.parent_id = task.id -- 取消传播树：记录 fork 父
    S.inherit_deadline(child, task) -- 继承父剩余 deadline
    local handle = { id = child.id }
    S.emit_trace(opts, {
      type = "fork",
      task_id = task.id,
      child_id = child.id,
    })
    task.answer = Coro.resume(task.answer, handle)
    -- 不 return：父任务继续；子任务留给主循环驱动
  end

  function H.join(nursery, task, req)
    local opts = nursery.opts
    local h = req.handle
    assert(type(h) == "table" and type(h.id) == "number",
      "fx_sched: join requires handle {id=number}")
    local child = nursery.tasks[h.id]
    assert(child, "fx_sched: join unknown handle id=" .. tostring(h.id))
    S.emit_trace(opts, {
      type = "join",
      task_id = task.id,
      target_id = h.id,
    })
    local want_cancel = not not req.cancel_siblings
    return S.join_finished_or_park(nursery, task, child, want_cancel)
  end

  function H.join_handles(nursery, task, req)
    local handles = req.handles
    assert(type(handles) == "table", "fx_sched: join_handles requires .handles")
    if #handles == 0 then
      task.answer = Coro.resume(task.answer, {})
    else
      local targets = {}
      local values = {}
      local done_n = 0
      local fail_now, abort_now, stop_now
      for i, h in ipairs(handles) do
        assert(type(h) == "table" and type(h.id) == "number",
          "fx_sched: join_handles handle must be {id=number}")
        local child = nursery.tasks[h.id]
        assert(child, "fx_sched: join_handles unknown id=" .. tostring(h.id))
        targets[i] = child.id
        if child.finished then
          if Coro.isFailed(child.answer) then
            fail_now = child
            break
          elseif Coro.isAborted(child.answer) then
            abort_now = child
            break
          elseif Coro.isStopped(child.answer) then
            stop_now = child
            break
          elseif Coro.isDone(child.answer) then
            values[i] = child.result
            done_n = done_n + 1
          end
        end
      end
      local want_cancel = not not req.cancel_siblings
      if fail_now then
        task.answer = Coro.Failed(fail_now.answer.error)
        return "failed"
      end
      if abort_now then
        task.answer = Coro.Aborted(abort_now.answer.reason)
        return "aborted"
      end
      if stop_now then
        task.answer = Coro.Stopped(stop_now.answer.reason)
        return "stopped"
      end
      if done_n >= #handles then
        task.answer = Coro.resume(task.answer, values)
        if want_cancel then
          local joined = {}
          for _, tid in ipairs(targets) do
            joined[tid] = true
          end
          S.cancel_fork_siblings(nursery, joined, task.id, "cancelled")
        end
      else
        task.parked = "join_all"
        task.join_targets = targets
        task.join_values = values
        task.join_done = done_n
        task.join_cancel_siblings = want_cancel
        for i, tid in ipairs(targets) do
          local child = nursery.tasks[tid]
          if not child.finished then
            child.joiners[#child.joiners + 1] = task.id
          end
        end
        return "parked"
      end
    end
  end
end

return Mod
