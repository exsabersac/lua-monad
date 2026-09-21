-- fx_sched_drive_lane.lua — lane / lane_join / lane_stop / lane_abort 分派
local Coro = require("coro")

local Mod = {}

function Mod.install(S)
  local H = S.drive_handlers

  function H.lane(nursery, task, req)
    local opts = nursery.opts
    local name = req.name
    assert(type(name) == "string" and name ~= "",
      "fx_sched: lane requires non-empty string .name")
    local ma = req.task
    assert(ma ~= nil, "fx_sched: lane requires .task")
    if nursery.lanes == nil then
      nursery.lanes = {}
    end
    local existing_id = nursery.lanes[name]
    if existing_id ~= nil then
      local old = nursery.tasks[existing_id]
      if old and not old.finished then
        task.answer = Coro.Failed({ tag = "lane_busy", name = name })
        return "failed"
      end
    end
    local child = S.alloc_task(nursery, ma)
    child.parent_id = task.id
    child.lane_name = name
    S.inherit_deadline(child, task)
    nursery.lanes[name] = child.id
    local handle = { id = child.id, name = name }
    S.emit_trace(opts, {
      type = "fork",
      task_id = task.id,
      child_id = child.id,
      lane = name,
    })
    task.answer = Coro.resume(task.answer, handle)
  end

  function H.lane_join(nursery, task, req)
    local opts = nursery.opts
    local name = req.name
    assert(type(name) == "string" and name ~= "",
      "fx_sched: lane_join requires non-empty string .name")
    local id = nursery.lanes and nursery.lanes[name]
    if id == nil then
      task.answer = Coro.Failed({ tag = "lane_unknown", name = name })
      return "failed"
    end
    local child = nursery.tasks[id]
    if child == nil then
      task.answer = Coro.Failed({ tag = "lane_unknown", name = name })
      return "failed"
    end
    S.emit_trace(opts, {
      type = "join",
      task_id = task.id,
      target_id = id,
      lane = name,
    })
    local want_cancel = not not req.cancel_siblings
    if child.finished then
      local st = S.apply_finished_child_to_waiter(task, child, want_cancel, nursery)
      if st then
        return st
      end
    else
      task.parked = "join"
      task.join_target = child.id
      task.join_cancel_siblings = want_cancel
      child.joiners[#child.joiners + 1] = task.id
      return "parked"
    end
  end

  local function lane_stop_or_abort(nursery, task, req)
    local opts = nursery.opts
    local name = req.name
    assert(type(name) == "string" and name ~= "",
      "fx_sched: " .. req.kind .. " requires non-empty string .name")
    local mode = (req.kind == "lane_abort") and "abort" or "stop"
    local reason = req.reason
    S.emit_trace(opts, {
      type = "cancel",
      task_id = task.id,
      lane = name,
      mode = mode,
    })
    local ok = S.stop_named_lane(nursery, name, mode, reason)
    task.answer = Coro.resume(task.answer, ok)
  end

  H.lane_stop = lane_stop_or_abort
  H.lane_abort = lane_stop_or_abort
end

return Mod
