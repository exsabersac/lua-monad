-- fx_sched_nursery.lua — nursery/task、deadline、cancel/stop、proxy 宿主、terminal/join、group/timeout
local Coro = require("coro")
local Cont = require("cont")

local Mod = {}

function Mod.install(S)

function S.new_nursery(handlers, opts)
  return {
    next_id = 0,
    tasks = {}, -- id → task
    lanes = {}, -- name → task_id（命名 lane；≈ tabMachine c:start("t1")）
    handlers = handlers or {},
    opts = opts or {},
    root_id = nil,
  }
end

function S.alloc_task(nursery, ma, pre_answer)
  nursery.next_id = nursery.next_id + 1
  local id = nursery.next_id
  local t = {
    id = id,
    nursery = nursery,
    answer = pre_answer ~= nil and pre_answer or Coro.start(ma),
    waiting = false,
    deadline = nil,
    finished = false,
    parked = nil,
    join_target = nil,
    join_targets = nil,
    join_values = nil,
    join_cancel_siblings = nil, -- join / join_handles 成功后是否取消兄弟
    group_ref = nil,
    group_pos = nil,
    parent_id = nil, -- fork 时记录父任务 id（取消传播树）
    deadline_abs = nil, -- 继承的绝对截止时间（游戏时间或墙钟）
    joiners = {},
    fail_index = nil,
    result = nil,
    timer_handle = nil,
    event_handle = nil,
  }
  nursery.tasks[id] = t
  return t
end

function S.live_count(nursery)
  local n = 0
  for _, t in pairs(nursery.tasks) do
    if not t.finished then
      n = n + 1
    end
  end
  return n
end

function S.is_runnable(task)
  return not task.finished and not task.waiting and task.parked == nil
end

function S.clear_task_waits(task)
  -- 等待方被取消：可选反向停 proxy 目标（须在清 wait 前，保留 join_target）
  if S.apply_proxy_stop_host and task.proxy_stop_host then
    S.apply_proxy_stop_host(task)
  end
  local nursery = task.nursery
  local opts = (nursery and nursery.opts) or {}
  local scheduler = opts.scheduler
  if task._timer_flag then
    task._timer_flag.cancelled = true
    task._timer_flag = nil
  end
  if task.timer_handle ~= nil then
    if scheduler and type(scheduler.cancel) == "function" then
      scheduler.cancel(task.timer_handle)
    end
    task.timer_handle = nil
  end
  if task._event_flag then
    task._event_flag.cancelled = true
    task._event_flag = nil
  end
  if task.event_handle ~= nil then
    local unlisten = task._unlisten or opts.unlisten
    if unlisten == nil and scheduler then
      unlisten = scheduler.unlisten
    end
    if type(unlisten) == "function" then
      unlisten(task.event_handle)
    end
    task.event_handle = nil
    task._unlisten = nil
  end
  S.detach_chan_waiter(task, true)
  -- supervise 等待 backoff 时，父 parked；cancel 须拆掉 scheduler handle
  if task.waiting_group and task.waiting_group.mode == "supervise" then
    S.clear_supervise_backoff(task.waiting_group, opts, task.nursery)
  end
  task.deadline = nil
  task.waiting = false
  task.waiting_event = false
  task._wait_until_pred = nil
  task._wait_until_interval = nil
  task._wait_until_next = nil
end

function S.mark_finished(task)
  S.clear_task_waits(task)
  task.finished = true
  task.parked = nil
end

function S.force_stop_task_answer(answer, reason)
  return Coro.force_stop(answer, reason or "cancelled")
end

function S.clear_supervise_backoff(group, opts, nursery)
  if group == nil then
    return
  end
  if group._backoff_flag then
    group._backoff_flag.cancelled = true
    group._backoff_flag = nil
  end
  if group._backoff_handle ~= nil then
    local scheduler = opts and opts.scheduler
    if scheduler and type(scheduler.cancel) == "function" then
      scheduler.cancel(group._backoff_handle)
    end
    group._backoff_handle = nil
  end
  if group._backoff_task_id ~= nil and nursery ~= nil then
    local t = nursery.tasks[group._backoff_task_id]
    group._backoff_task_id = nil
    if t and not t.finished then
      S.clear_task_waits(t)
      t.answer = S.force_stop_task_answer(t.answer, "cancelled")
      t._supervise_backoff_group = nil
      S.mark_finished(t)
      t._terminal_handled = true
    end
  end
end

function S.apply_deadline_abs(task, abs)
  if abs == nil or task == nil then
    return
  end
  if task.deadline_abs == nil or abs < task.deadline_abs then
    task.deadline_abs = abs
  end
end

function S.inherit_deadline(child, parent)
  if child == nil or parent == nil then
    return
  end
  if parent.deadline_abs ~= nil then
    S.apply_deadline_abs(child, parent.deadline_abs)
  end
end

function S.cancel_descendants(nursery, ancestor_id, reason)
  reason = reason or "cancelled"
  local function is_descendant(task)
    local pid = task.parent_id
    local guard = 0
    while pid ~= nil and guard < 10000 do
      guard = guard + 1
      if pid == ancestor_id then
        return true
      end
      local p = nursery.tasks[pid]
      if not p then
        return false
      end
      pid = p.parent_id
    end
    return false
  end
  local function depth_of(task)
    local d = 0
    local pid = task.parent_id
    local guard = 0
    while pid ~= nil and guard < 10000 do
      guard = guard + 1
      d = d + 1
      local p = nursery.tasks[pid]
      if not p then
        break
      end
      pid = p.parent_id
    end
    return d
  end
  local ids = {}
  for id, t in pairs(nursery.tasks) do
    if t and not t.finished and is_descendant(t) then
      ids[#ids + 1] = id
    end
  end
  -- 深者优先，便于子 finally 先于祖先副作用
  table.sort(ids, function(a, b)
    local da = depth_of(nursery.tasks[a])
    local db = depth_of(nursery.tasks[b])
    if da ~= db then
      return da > db
    end
    return a < b
  end)
  for _, id in ipairs(ids) do
    local t = nursery.tasks[id]
    if t and not t.finished then
      S.clear_task_waits(t)
      t.answer = S.force_stop_task_answer(t.answer, reason)
      if not t._terminal_handled then
        S.on_task_terminal(nursery, t, "stopped")
      else
        S.mark_finished(t)
      end
    end
  end
end

function S.cancel_siblings(nursery, group, except_id)
  for _, cid in ipairs(group.child_ids) do
    if cid ~= except_id then
      local c = nursery.tasks[cid]
      if c and not c.finished then
        -- 先停后代（fork 子树），再停组员本身
        S.cancel_descendants(nursery, cid, "cancelled")
        S.clear_task_waits(c)
        c.answer = S.force_stop_task_answer(c.answer, "cancelled")
        S.mark_finished(c)
        -- 不再递归唤醒 joiners（结构化组内取消）
      end
    end
  end
end

function S.cancel_fork_siblings(nursery, joined_ids, joiner_id, reason)
  reason = reason or "cancelled"
  local parents = {}
  for jid, _ in pairs(joined_ids) do
    local jt = nursery.tasks[jid]
    if jt and jt.parent_id then
      parents[jt.parent_id] = true
    end
  end
  local ids = {}
  for id, _ in pairs(nursery.tasks) do
    ids[#ids + 1] = id
  end
  table.sort(ids)
  for _, id in ipairs(ids) do
    if id ~= joiner_id and not joined_ids[id] then
      local t = nursery.tasks[id]
      if t and not t.finished and t.parent_id and parents[t.parent_id] then
        S.cancel_descendants(nursery, id, reason)
        S.clear_task_waits(t)
        t.answer = S.force_stop_task_answer(t.answer, reason)
        -- 标记终态并唤醒仍在等该兄弟的 join 方
        if not t._terminal_handled then
          S.on_task_terminal(nursery, t, "stopped")
        else
          S.mark_finished(t)
        end
      end
    end
  end
end

function S.stop_task(nursery, child, mode, reason)
  if child == nil or child.finished then
    return false
  end
  if mode == "abort" then
    reason = reason or "abort"
  else
    reason = reason or "stop"
  end
  S.cancel_descendants(nursery, child.id, reason)
  S.clear_task_waits(child)
  if mode == "abort" then
    if Coro.isYielded(child.answer) and type(child.answer.abort) == "function" then
      child.answer.abort(reason)
    end
    child.answer = Coro.Aborted(reason)
    if not child._terminal_handled then
      S.on_task_terminal(nursery, child, "aborted")
    else
      S.mark_finished(child)
    end
  else
    child.answer = S.force_stop_task_answer(child.answer, reason)
    if not child._terminal_handled then
      S.on_task_terminal(nursery, child, "stopped")
    else
      S.mark_finished(child)
    end
  end
  return true
end

function S.stop_named_lane(nursery, name, mode, reason)
  local lanes = nursery.lanes
  if lanes == nil then
    return false
  end
  local id = lanes[name]
  if id == nil then
    return false
  end
  local child = nursery.tasks[id]
  if mode == "abort" then
    reason = reason or "lane_abort"
  else
    reason = reason or "lane_stop"
  end
  return S.stop_task(nursery, child, mode, reason)
end

function S.resolve_proxy_target(nursery, proxy)
  if type(proxy) ~= "table" or not proxy._is_proxy then
    return nil, "unknown"
  end
  if proxy.flow ~= nil then
    return nil, "flow"
  end
  if type(proxy.id) == "number" then
    local child = nursery.tasks[proxy.id]
    if child == nil then
      return nil, "unknown"
    end
    return child, "task"
  end
  if type(proxy.name) == "string" and proxy.name ~= "" then
    local id = nursery.lanes and nursery.lanes[proxy.name]
    if id == nil then
      return nil, "unknown"
    end
    local child = nursery.tasks[id]
    if child == nil then
      return nil, "unknown"
    end
    return child, "lane"
  end
  return nil, "unknown"
end

function S.detach_joiner(host, joiner_id)
  if host == nil or host.joiners == nil then
    return
  end
  local kept = {}
  for _, jid in ipairs(host.joiners) do
    if jid ~= joiner_id then
      kept[#kept + 1] = jid
    end
  end
  host.joiners = kept
end

function S.apply_proxy_stop_host(task)
  if not task.proxy_stop_host then
    return
  end
  task.proxy_stop_host = nil
  local reason = "proxy_stop_host"
  local flow = task.proxy_host_flow
  local host_id = task.join_target
  local nursery = task.nursery
  task.proxy_host_flow = nil
  -- 先从 joiners / flow 等待表摘掉自己
  if nursery and host_id then
    S.detach_joiner(nursery.tasks[host_id], task.id)
  end
  if flow and flow._proxy_joiners then
    local kept = {}
    for _, e in ipairs(flow._proxy_joiners) do
      if not (e.nursery == nursery and e.task_id == task.id) then
        kept[#kept + 1] = e
      end
    end
    flow._proxy_joiners = kept
  end
  task.join_target = nil
  if task.parked == "join" or task.parked == "proxy_flow" then
    task.parked = nil
  end
  if flow ~= nil then
    if not flow.done and type(flow.cancel) == "function" then
      flow.cancel(reason)
    end
    return
  end
  if nursery and host_id then
    local host = nursery.tasks[host_id]
    if host and not host.finished then
      S.stop_task(nursery, host, "stop", reason)
    end
  end
end

function S.map_flow_result_to_joiner(nursery, j, result)
  if result.ok then
    j.answer = Coro.resume(j.answer, result.value)
  elseif result.aborted then
    j.answer = Coro.Aborted(result.reason)
    S.mark_finished(j)
    S.on_task_terminal(nursery, j, "aborted")
  elseif result.stopped then
    j.answer = Coro.Stopped(result.reason)
    S.mark_finished(j)
    S.on_task_terminal(nursery, j, "stopped")
  elseif result.failed then
    j.answer = Coro.Failed(result.error)
    S.mark_finished(j)
    S.on_task_terminal(nursery, j, "failed")
  else
    error("fx_sched: flow proxy_join unexpected result shape")
  end
end

function S.notify_flow_proxy_joiners(flow)
  local list = flow._proxy_joiners
  if list == nil or #list == 0 then
    return
  end
  flow._proxy_joiners = {}
  local result = flow.result
  for _, e in ipairs(list) do
    local nursery = e.nursery
    local j = nursery and nursery.tasks[e.task_id]
    if j and not j.finished and j.parked == "proxy_flow" then
      j.parked = nil
      j.proxy_stop_host = nil
      j.proxy_host_flow = nil
      S.map_flow_result_to_joiner(nursery, j, result)
      local pump = nursery.opts and nursery.opts._pump
      if type(pump) == "function" then
        pump()
      end
    end
  end
end

function S.attach_flow_proxy_method(flow)
  --- flow:proxy(opts?) → Proxy（轻量 tabProxy；opts.stop_host_when_stop 反向停本 flow）
  function flow:proxy(opts)
    opts = opts or {}
    return {
      _is_proxy = true,
      flow = flow,
      stop_host_when_stop = not not opts.stop_host_when_stop,
    }
  end
end

function S.cancel_all_unfinished(nursery, reason)
  reason = reason or "cancelled"
  local ids = {}
  for id, _ in pairs(nursery.tasks) do
    ids[#ids + 1] = id
  end
  table.sort(ids)
  for _, id in ipairs(ids) do
    local t = nursery.tasks[id]
    if t and not t.finished then
      S.clear_task_waits(t)
      t.answer = S.force_stop_task_answer(t.answer, reason)
      S.mark_finished(t)
      t._terminal_handled = true
    end
  end
end

function S.settle_group(nursery, group, status, child)
  if group.settled then
    return
  end
  group.settled = true
  local parent = nursery.tasks[group.parent_id]
  if not parent or parent.finished then
    return
  end
  parent.parked = nil
  if status == "done" and group.mode == "all" then
    parent.answer = Coro.resume(parent.answer, group.values)
    -- 父任务回到可运行，由主循环继续 drive
  elseif status == "done" and group.mode == "any" then
    local payload = { value = child.result, index = child.group_pos }
    parent.answer = Coro.resume(parent.answer, payload)
    S.cancel_siblings(nursery, group, child.id)
  elseif status == "done" and group.mode == "timeout" then
    -- 子角色：body → 成功；timer → 超时 Failed
    if child.timeout_role == "timer" then
      parent.answer = Coro.Failed(group.on_timeout or "timeout")
      S.cancel_siblings(nursery, group, child.id)
      S.on_task_terminal(nursery, parent, "failed")
    else
      -- body 先完成
      parent.answer = Coro.resume(parent.answer, child.result)
      S.cancel_siblings(nursery, group, child.id)
    end
  elseif status == "done" and group.mode == "supervise" then
    S.clear_supervise_backoff(group, nursery.opts, nursery)
    parent.waiting_group = nil
    parent.answer = Coro.resume(parent.answer, child.result)
  elseif status == "failed" or status == "stopped" or status == "aborted" then
    if group.mode == "supervise" then
      S.clear_supervise_backoff(group, nursery.opts, nursery)
      parent.waiting_group = nil
    end
    if status == "failed" then
      parent.answer = Coro.Failed(child.answer.error)
    elseif status == "stopped" then
      parent.answer = Coro.Stopped(child.answer.reason or "cancelled")
    else
      parent.answer = Coro.Aborted(child.answer.reason or "aborted")
    end
    parent.fail_index = child.group_pos
    S.cancel_siblings(nursery, group, child.id)
    S.on_task_terminal(nursery, parent, status)
  end
end

function S.on_task_terminal(nursery, task, status)
  if task._terminal_handled then
    return
  end
  task._terminal_handled = true

  if status == "done" then
    task.result = task.answer.value
  end
  S.mark_finished(task)

  -- supervise backoff 等待任务（非 group 子）：到期后启下一轮
  if task._supervise_backoff_group then
    local g = task._supervise_backoff_group
    task._supervise_backoff_group = nil
    if g._backoff_task_id == task.id then
      g._backoff_task_id = nil
    end
    if status == "done" and not g.settled then
      S.spawn_supervise_child(nursery, g)
    end
    -- Stopped/Failed of backoff：cancel 路径，不再重启
    S.try_complete_joins(nursery, task, status)
    return
  end

  -- 结构化 when_all / when_any / timeout / supervise
  local group = task.group_ref
  if group and not group.settled then
    if group.mode == "supervise" then
      S.try_supervise_after_child(nursery, group, task, status)
    elseif status == "done" then
      group.values[task.group_pos] = task.result
      group.done_count = group.done_count + 1
      if group.mode == "any" or group.mode == "timeout" then
        -- any / timeout：第一个 Done 即结算（timeout 下再按 role 区分成功/超时）
        S.settle_group(nursery, group, "done", task)
      elseif group.done_count >= group.n then
        S.settle_group(nursery, group, "done", task)
      end
    elseif status == "failed" then
      if group.mode == "all" or group.mode == "timeout" then
        -- timeout：body Failed 立刻传播（并取消 timer）
        S.settle_group(nursery, group, "failed", task)
      else
        -- when_any：失败也算终态；若全部终态无一 Done，由主循环收尾
        group.done_count = group.done_count + 1
        if group.done_count >= group.n then
          -- 找第一个 failed / stopped
          for _, cid in ipairs(group.child_ids) do
            local c = nursery.tasks[cid]
            if c and Coro.isFailed(c.answer) then
              S.settle_group(nursery, group, "failed", c)
              break
            end
          end
          if not group.settled then
            for _, cid in ipairs(group.child_ids) do
              local c = nursery.tasks[cid]
              if c and Coro.isAborted(c.answer) then
                S.settle_group(nursery, group, "aborted", c)
                break
              end
            end
          end
          if not group.settled then
            for _, cid in ipairs(group.child_ids) do
              local c = nursery.tasks[cid]
              if c and Coro.isStopped(c.answer) then
                S.settle_group(nursery, group, "stopped", c)
                break
              end
            end
          end
          if not group.settled then
            local parent = nursery.tasks[group.parent_id]
            if parent and not parent.finished then
              parent.parked = nil
              parent.answer = Coro.Failed("when_any: no winner")
              S.mark_finished(parent)
              group.settled = true
            end
          end
        end
      end
    elseif status == "stopped" or status == "aborted" then
      if group.mode == "all" or group.mode == "timeout" then
        -- timeout：body Stopped/Aborted 立刻传播（并取消 timer）
        S.settle_group(nursery, group, status, task)
      else
        group.done_count = group.done_count + 1
        if group.done_count >= group.n then
          for _, cid in ipairs(group.child_ids) do
            local c = nursery.tasks[cid]
            if c and Coro.isFailed(c.answer) then
              S.settle_group(nursery, group, "failed", c)
              break
            end
          end
          if not group.settled then
            for _, cid in ipairs(group.child_ids) do
              local c = nursery.tasks[cid]
              if c and Coro.isAborted(c.answer) then
                S.settle_group(nursery, group, "aborted", c)
                break
              end
            end
          end
          if not group.settled then
            for _, cid in ipairs(group.child_ids) do
              local c = nursery.tasks[cid]
              if c and Coro.isStopped(c.answer) then
                S.settle_group(nursery, group, "stopped", c)
                break
              end
            end
          end
        end
      end
    end
  end

  -- 非结构化 fork/join：唤醒等待本任务的 joiners
  S.try_complete_joins(nursery, task, status)
end

function S.try_complete_joins(nursery, finished_task, status)
  local joiners = finished_task.joiners
  finished_task.joiners = {}
  for _, jid in ipairs(joiners) do
    local j = nursery.tasks[jid]
    if j and not j.finished then
      if j.parked == "join" and j.join_target == finished_task.id then
        j.parked = nil
        j.join_target = nil
        j.proxy_stop_host = nil
        j.proxy_host_flow = nil
        if status == "done" then
          j.answer = Coro.resume(j.answer, finished_task.result)
          if j.join_cancel_siblings then
            j.join_cancel_siblings = nil
            S.cancel_fork_siblings(nursery, { [finished_task.id] = true }, j.id, "cancelled")
          end
        elseif status == "failed" then
          j.answer = Coro.Failed(finished_task.answer.error)
          S.mark_finished(j)
          -- join 失败也要通知再上层 joiners（若有）
          S.on_task_terminal(nursery, j, "failed")
        elseif status == "aborted" then
          j.answer = Coro.Aborted(finished_task.answer.reason)
          S.mark_finished(j)
          S.on_task_terminal(nursery, j, "aborted")
        elseif status == "stopped" then
          j.answer = Coro.Stopped(finished_task.answer.reason)
          S.mark_finished(j)
          S.on_task_terminal(nursery, j, "stopped")
        end
      elseif j.parked == "join_all" and j.join_targets then
        local idx = nil
        for i, tid in ipairs(j.join_targets) do
          if tid == finished_task.id then
            idx = i
            break
          end
        end
        if idx then
          if status == "failed" then
            j.parked = nil
            j.answer = Coro.Failed(finished_task.answer.error)
            S.mark_finished(j)
            S.on_task_terminal(nursery, j, "failed")
          elseif status == "aborted" then
            j.parked = nil
            j.answer = Coro.Aborted(finished_task.answer.reason)
            S.mark_finished(j)
            S.on_task_terminal(nursery, j, "aborted")
          elseif status == "stopped" then
            j.parked = nil
            j.answer = Coro.Stopped(finished_task.answer.reason)
            S.mark_finished(j)
            S.on_task_terminal(nursery, j, "stopped")
          elseif status == "done" then
            j.join_values[idx] = finished_task.result
            j.join_done = (j.join_done or 0) + 1
            if j.join_done >= #j.join_targets then
              j.parked = nil
              local values = j.join_values
              local targets = j.join_targets
              local want_cancel = j.join_cancel_siblings
              j.join_targets = nil
              j.join_values = nil
              j.join_cancel_siblings = nil
              j.answer = Coro.resume(j.answer, values)
              if want_cancel and targets then
                local joined = {}
                for _, tid in ipairs(targets) do
                  joined[tid] = true
                end
                S.cancel_fork_siblings(nursery, joined, j.id, "cancelled")
              end
            end
          end
        end
      end
    end
  end
end

function S.start_group(nursery, parent, req, mode)
  local mas = req.tasks or {}
  local n = #mas
  if n == 0 then
    if mode == "all" then
      parent.answer = Coro.resume(parent.answer, {})
      return "continued"
    end
    parent.answer = Coro.Failed("when_any: empty task list")
    return "failed"
  end

  local group = {
    parent_id = parent.id,
    mode = mode,
    child_ids = {},
    values = {},
    done_count = 0,
    n = n,
    settled = false,
  }
  for i = 1, n do
    local child = S.alloc_task(nursery, mas[i])
    child.group_ref = group
    child.group_pos = i
    child.parent_id = parent.id -- 结构化并行也挂到父，便于 session cancel 树
    S.inherit_deadline(child, parent)
    group.child_ids[i] = child.id
  end
  parent.parked = "group"
  parent.waiting_group = group -- 正在等待的组（≠ 作为子任务的 group_ref）
  return "parked"
end

function S.start_timeout_race(nursery, parent, req)
  local ma = req.task
  local secs = req.seconds or 0
  local on_timeout = req.on_timeout or "timeout"
  assert(ma ~= nil, "fx_sched: with_timeout requires .task")

  local opts = nursery.opts or {}
  local tnow = S.clock_now(opts)
  local abs = tnow + secs
  if parent.deadline_abs ~= nil and parent.deadline_abs < abs then
    abs = parent.deadline_abs
  end
  local effective = abs - tnow
  if effective < 0 then
    effective = 0
  end

  local group = {
    parent_id = parent.id,
    mode = "timeout",
    child_ids = {},
    values = {},
    done_count = 0,
    n = 2,
    settled = false,
    on_timeout = on_timeout,
  }

  local body = S.alloc_task(nursery, ma)
  body.group_ref = group
  body.group_pos = 1
  body.timeout_role = "body"
  body.parent_id = parent.id
  S.apply_deadline_abs(body, abs)
  group.child_ids[1] = body.id

  local timer_ma = Coro.yield({ kind = "wait", seconds = effective }) >> function(_)
    return Cont.unit(true)
  end
  local timer = S.alloc_task(nursery, timer_ma)
  timer.group_ref = group
  timer.group_pos = 2
  timer.timeout_role = "timer"
  timer.parent_id = parent.id
  group.child_ids[2] = timer.id

  parent.parked = "group"
  parent.waiting_group = group
  return "parked"
end

function S.make_settled_flow(result)
  local flow = {
    _is_flow = true,
    done = true,
    result = result,
    suspended = false,
    nursery = nil,
    root = nil,
    _deferred = {},
  }
  function flow.suspend()
  end
  function flow.resume()
    return flow.result
  end
  function flow.is_suspended()
    return false
  end
  function flow.is_done()
    return true
  end
  function flow.pump()
    return flow.result
  end
  function flow.cancel(_reason)
    return flow.result
  end
  S.attach_flow_proxy_method(flow)
  return flow
end

end

return Mod
