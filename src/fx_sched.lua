-- fx_sched.lua — 并行 / nursery 调度器（时间轮）
--
-- 统一驱动：
--   · run_session(root_ma) — fx.run 主路径：动态任务集（nursery），支持
--       wait / connect/click / when_all·when_any / fork·join·join_handles / with_timeout
--   · run_parallel(tasks, mode) — 顶层 WhenAll/WhenAny（内部走 session）
--
-- Cont Coro 编码：每个任务 Coro.start；wait 在多任务时登记 deadline（墙钟），
-- 单任务时可走 handlers.wait（兼容瞬时 mock）；fork 立刻把 handle 还给父任务。
-- 若 opts.scheduler（或 opts.game）提供，wait 走 schedule/cancel，不再 busy_wait；
-- session 可异步完成（timer 回调 resume + pump）。

local Coro = require("coro")
local Cont = require("cont")

local M = {}

------------------------------------------------------------
-- 墙钟时间（并行 wait 的 deadline / sleep 必须一致）
-- os.clock 是 CPU 时间，sleep 期间几乎不推进 → 勿用于 deadline
------------------------------------------------------------

local _virt = 0

local function probe_wall()
  local ok, socket = pcall(require, "socket")
  if ok and type(socket) == "table" and type(socket.gettime) == "function" then
    return socket.gettime()
  end
  local f = io.popen("date +%s.%N 2>/dev/null")
  if f then
    local s = f:read("*a")
    f:close()
    local n = tonumber(s)
    if n then
      return n
    end
  end
  f = io.popen("python3 -c 'import time; print(time.time())' 2>/dev/null")
  if f then
    local s = f:read("*a")
    f:close()
    local n = tonumber(s)
    if n then
      return n
    end
  end
  return nil
end

local function wall_now()
  local w = probe_wall()
  if w then
    return w
  end
  return _virt
end

local function now()
  return wall_now()
end

local function busy_wait(seconds)
  if not seconds or seconds <= 0 then
    return
  end
  local ok, socket = pcall(require, "socket")
  if ok and type(socket) == "table" and type(socket.sleep) == "function" then
    socket.sleep(seconds)
  elseif package.config:sub(1, 1) == "/" then
    os.execute(string.format("sleep %.3f", seconds))
  else
    _virt = _virt + seconds
    return
  end
  if not probe_wall() then
    _virt = _virt + seconds
  end
end

M.busy_wait = busy_wait
M.now = now

local function is_cancelled(cancel)
  if cancel == nil then
    return false
  end
  if type(cancel) == "function" then
    return not not cancel()
  end
  if type(cancel) == "table" then
    return not not cancel.cancelled
  end
  error("fx_sched: opts.cancel must be function or {cancelled=...}", 2)
end

------------------------------------------------------------
-- Nursery / Session
------------------------------------------------------------

-- 任务槽：
--   id, answer, waiting, deadline, finished
--   parked = nil | "join" | "join_all" | "group"
--   join_target / join_targets / join_values
--   group_ref, group_pos
--   joiners = { task_id, ... }  -- 等我结束的 join 方
--   fail_index — when_all 失败时记下子下标

local function new_nursery(handlers, opts)
  return {
    next_id = 0,
    tasks = {}, -- id → task
    handlers = handlers or {},
    opts = opts or {},
    root_id = nil,
  }
end

local function alloc_task(nursery, ma)
  nursery.next_id = nursery.next_id + 1
  local id = nursery.next_id
  local t = {
    id = id,
    nursery = nursery,
    answer = Coro.start(ma),
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
    joiners = {},
    fail_index = nil,
    result = nil,
    timer_handle = nil,
    event_handle = nil,
  }
  nursery.tasks[id] = t
  return t
end

local function live_count(nursery)
  local n = 0
  for _, t in pairs(nursery.tasks) do
    if not t.finished then
      n = n + 1
    end
  end
  return n
end

local function is_runnable(task)
  return not task.finished and not task.waiting and task.parked == nil
end

-- 清除 wait / wait_event 占用的 timer / listener；迟到回调靠 cancelled 旗标忽略
local function clear_task_waits(task)
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
  task.deadline = nil
  task.waiting = false
  task.waiting_event = false
end

local function mark_finished(task)
  clear_task_waits(task)
  task.finished = true
  task.parked = nil
end

-- 经 with_finally.abort 停任务，保证 finally 执行
local function force_stop_task_answer(answer, reason)
  return Coro.force_stop(answer, reason or "cancelled")
end

-- 前向声明
local drive_until_block
local on_task_terminal
local settle_group
local try_complete_joins

local function cancel_siblings(nursery, group, except_id)
  for _, cid in ipairs(group.child_ids) do
    if cid ~= except_id then
      local c = nursery.tasks[cid]
      if c and not c.finished then
        clear_task_waits(c)
        c.answer = force_stop_task_answer(c.answer, "cancelled")
        mark_finished(c)
        -- 不再递归唤醒 joiners（结构化组内取消）
      end
    end
  end
end


-- 取消同一 fork 父任务下、未纳入 except_ids 的未完成兄弟（及其仍在跑的后代由 session 级 cancel 覆盖）
-- 用于 join/join_handles 的 opts.cancel_siblings
local function cancel_fork_siblings(nursery, joined_ids, joiner_id, reason)
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
        clear_task_waits(t)
        t.answer = force_stop_task_answer(t.answer, reason)
        -- 标记终态并唤醒仍在等该兄弟的 join 方
        if not t._terminal_handled then
          on_task_terminal(nursery, t, "stopped")
        else
          mark_finished(t)
        end
      end
    end
  end
end

-- session 级取消：停止 nursery 内全部未完成任务
local function cancel_all_unfinished(nursery, reason)
  reason = reason or "cancelled"
  local ids = {}
  for id, _ in pairs(nursery.tasks) do
    ids[#ids + 1] = id
  end
  table.sort(ids)
  for _, id in ipairs(ids) do
    local t = nursery.tasks[id]
    if t and not t.finished then
      clear_task_waits(t)
      t.answer = force_stop_task_answer(t.answer, reason)
      mark_finished(t)
      t._terminal_handled = true
    end
  end
end

settle_group = function(nursery, group, status, child)
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
    cancel_siblings(nursery, group, child.id)
  elseif status == "done" and group.mode == "timeout" then
    -- 子角色：body → 成功；timer → 超时 Failed
    if child.timeout_role == "timer" then
      parent.answer = Coro.Failed(group.on_timeout or "timeout")
      cancel_siblings(nursery, group, child.id)
      on_task_terminal(nursery, parent, "failed")
    else
      -- body 先完成
      parent.answer = Coro.resume(parent.answer, child.result)
      cancel_siblings(nursery, group, child.id)
    end
  elseif status == "failed" then
    parent.answer = Coro.Failed(child.answer.error)
    parent.fail_index = child.group_pos
    cancel_siblings(nursery, group, child.id)
    on_task_terminal(nursery, parent, "failed")
  elseif status == "stopped" then
    parent.answer = Coro.Stopped(child.answer.reason or "cancelled")
    parent.fail_index = child.group_pos
    cancel_siblings(nursery, group, child.id)
    on_task_terminal(nursery, parent, "stopped")
  end
end

-- 子任务终态后：推进 when_all/any 组，并唤醒 fork/join 等待方
on_task_terminal = function(nursery, task, status)
  if task._terminal_handled then
    return
  end
  task._terminal_handled = true

  if status == "done" then
    task.result = task.answer.value
  end
  mark_finished(task)

  -- 结构化 when_all / when_any
  local group = task.group_ref
  if group and not group.settled then
    if status == "done" then
      group.values[task.group_pos] = task.result
      group.done_count = group.done_count + 1
      if group.mode == "any" or group.mode == "timeout" then
        -- any / timeout：第一个 Done 即结算（timeout 下再按 role 区分成功/超时）
        settle_group(nursery, group, "done", task)
      elseif group.done_count >= group.n then
        settle_group(nursery, group, "done", task)
      end
    elseif status == "failed" then
      if group.mode == "all" or group.mode == "timeout" then
        -- timeout：body Failed 立刻传播（并取消 timer）
        settle_group(nursery, group, "failed", task)
      else
        -- when_any：失败也算终态；若全部终态无一 Done，由主循环收尾
        group.done_count = group.done_count + 1
        if group.done_count >= group.n then
          -- 找第一个 failed / stopped
          for _, cid in ipairs(group.child_ids) do
            local c = nursery.tasks[cid]
            if c and Coro.isFailed(c.answer) then
              settle_group(nursery, group, "failed", c)
              break
            end
          end
          if not group.settled then
            for _, cid in ipairs(group.child_ids) do
              local c = nursery.tasks[cid]
              if c and Coro.isStopped(c.answer) then
                settle_group(nursery, group, "stopped", c)
                break
              end
            end
          end
          if not group.settled then
            local parent = nursery.tasks[group.parent_id]
            if parent and not parent.finished then
              parent.parked = nil
              parent.answer = Coro.Failed("when_any: no winner")
              mark_finished(parent)
              group.settled = true
            end
          end
        end
      end
    elseif status == "stopped" then
      if group.mode == "all" or group.mode == "timeout" then
        -- timeout：body Stopped 立刻传播（并取消 timer）
        settle_group(nursery, group, "stopped", task)
      else
        group.done_count = group.done_count + 1
        if group.done_count >= group.n then
          for _, cid in ipairs(group.child_ids) do
            local c = nursery.tasks[cid]
            if c and Coro.isFailed(c.answer) then
              settle_group(nursery, group, "failed", c)
              break
            end
          end
          if not group.settled then
            for _, cid in ipairs(group.child_ids) do
              local c = nursery.tasks[cid]
              if c and Coro.isStopped(c.answer) then
                settle_group(nursery, group, "stopped", c)
                break
              end
            end
          end
        end
      end
    end
  end

  -- 非结构化 fork/join：唤醒等待本任务的 joiners
  try_complete_joins(nursery, task, status)
end

try_complete_joins = function(nursery, finished_task, status)
  local joiners = finished_task.joiners
  finished_task.joiners = {}
  for _, jid in ipairs(joiners) do
    local j = nursery.tasks[jid]
    if j and not j.finished then
      if j.parked == "join" and j.join_target == finished_task.id then
        j.parked = nil
        j.join_target = nil
        if status == "done" then
          j.answer = Coro.resume(j.answer, finished_task.result)
          if j.join_cancel_siblings then
            j.join_cancel_siblings = nil
            cancel_fork_siblings(nursery, { [finished_task.id] = true }, j.id, "cancelled")
          end
        elseif status == "failed" then
          j.answer = Coro.Failed(finished_task.answer.error)
          mark_finished(j)
          -- join 失败也要通知再上层 joiners（若有）
          on_task_terminal(nursery, j, "failed")
        elseif status == "stopped" then
          j.answer = Coro.Stopped(finished_task.answer.reason)
          mark_finished(j)
          on_task_terminal(nursery, j, "stopped")
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
            mark_finished(j)
            on_task_terminal(nursery, j, "failed")
          elseif status == "stopped" then
            j.parked = nil
            j.answer = Coro.Stopped(finished_task.answer.reason)
            mark_finished(j)
            on_task_terminal(nursery, j, "stopped")
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
                cancel_fork_siblings(nursery, joined, j.id, "cancelled")
              end
            end
          end
        end
      end
    end
  end
end

-- 启动 when_all / when_any：在同一 nursery 生成子任务并 park 父任务
local function start_group(nursery, parent, req, mode)
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
    local child = alloc_task(nursery, mas[i])
    child.group_ref = group
    child.group_pos = i
    child.parent_id = parent.id -- 结构化并行也挂到父，便于 session cancel 树
    group.child_ids[i] = child.id
  end
  parent.parked = "group"
  parent.waiting_group = group -- 正在等待的组（≠ 作为子任务的 group_ref）
  return "parked"
end


-- 启动 with_timeout：body 与 wait(seconds) 竞速
local function start_timeout_race(nursery, parent, req)
  local ma = req.task
  local secs = req.seconds or 0
  local on_timeout = req.on_timeout or "timeout"
  assert(ma ~= nil, "fx_sched: with_timeout requires .task")

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

  local body = alloc_task(nursery, ma)
  body.group_ref = group
  body.group_pos = 1
  body.timeout_role = "body"
  body.parent_id = parent.id
  group.child_ids[1] = body.id

  local timer_ma = Coro.yield({ kind = "wait", seconds = secs }) >> function(_)
    return Cont.unit(true)
  end
  local timer = alloc_task(nursery, timer_ma)
  timer.group_ref = group
  timer.group_pos = 2
  timer.timeout_role = "timer"
  timer.parent_id = parent.id
  group.child_ids[2] = timer.id

  parent.parked = "group"
  parent.waiting_group = group
  return "parked"
end

drive_until_block = function(nursery, task)
  local handlers = nursery.handlers
  local opts = nursery.opts

  while Coro.isYielded(task.answer) do
    if is_cancelled(opts.cancel) then
      clear_task_waits(task)
      task.answer = force_stop_task_answer(task.answer, "cancelled")
      return "stopped"
    end
    local req = task.answer.value
    assert(type(req) == "table" and req.kind ~= nil,
      "fx_sched: expected yield payload table with .kind")

    ------------------------------------------------------------
    -- wait
    ------------------------------------------------------------
    if req.kind == "wait" then
      local secs = req.seconds or 0
      local scheduler = opts.scheduler
      -- 外部 Scheduler：登记 timer，不 busy_wait；回调里 resume + pump
      if scheduler ~= nil then
        local flag = { cancelled = false }
        local handle = scheduler.schedule(secs, function()
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
            print(string.format("[fx.session] task#%d wait done (scheduler)", task.id))
          end
          task.answer = Coro.resume(task.answer, true)
          if type(opts._pump) == "function" then
            opts._pump()
          end
        end)
        task.timer_handle = handle
        task._timer_flag = flag
        task.waiting = true
        if opts.verbose_wait then
          print(string.format("[fx.session] task#%d wait %.3fs (scheduler)", task.id, secs))
        end
        return "wait"
      end
      -- 多任务（含 fork 子任务）走时间轮；单任务走 handlers.wait（兼容瞬时 mock）
      if live_count(nursery) > 1 then
        task.deadline = now() + secs
        task.waiting = true
        if opts.verbose_wait then
          print(string.format("[fx.session] task#%d wait %.3fs (deadline)", task.id, secs))
        end
        return "wait"
      else
        local handler = handlers.wait
        assert(handler, "fx_sched: no handler for kind=wait")
        local next_input = handler(req)
        task.answer = Coro.resume(task.answer, next_input)
      end

    ------------------------------------------------------------
    -- when_all / when_any（同 nursery 结构化并行）
    ------------------------------------------------------------
    elseif req.kind == "when_all" or req.kind == "when_any" then
      local mode = (req.kind == "when_any") and "any" or "all"
      local st = start_group(nursery, task, req, mode)
      if st == "failed" then
        return "failed"
      end
      if st == "parked" then
        return "parked"
      end
      -- continued（空 all）：继续循环

    ------------------------------------------------------------
    -- with_timeout：body 与 wait(deadline) 竞速
    ------------------------------------------------------------
    elseif req.kind == "with_timeout" then
      local st = start_timeout_race(nursery, task, req)
      if st == "parked" then
        return "parked"
      end

    ------------------------------------------------------------
    -- fork：启动子 Cont，立刻把 handle 还给父任务
    ------------------------------------------------------------
    elseif req.kind == "fork" then
      local ma = req.task
      assert(ma ~= nil, "fx_sched: fork requires .task")
      local child = alloc_task(nursery, ma)
      child.parent_id = task.id -- 取消传播树：记录 fork 父
      local handle = { id = child.id }
      task.answer = Coro.resume(task.answer, handle)
      -- 不 return：父任务继续；子任务留给主循环驱动

    ------------------------------------------------------------
    -- join：等单个 handle
    ------------------------------------------------------------
    elseif req.kind == "join" then
      local h = req.handle
      assert(type(h) == "table" and type(h.id) == "number",
        "fx_sched: join requires handle {id=number}")
      local child = nursery.tasks[h.id]
      assert(child, "fx_sched: join unknown handle id=" .. tostring(h.id))
      local want_cancel = not not req.cancel_siblings
      if child.finished then
        if Coro.isDone(child.answer) then
          task.answer = Coro.resume(task.answer, child.result)
          if want_cancel then
            cancel_fork_siblings(nursery, { [child.id] = true }, task.id, "cancelled")
          end
        elseif Coro.isFailed(child.answer) then
          task.answer = Coro.Failed(child.answer.error)
          return "failed"
        elseif Coro.isStopped(child.answer) then
          task.answer = Coro.Stopped(child.answer.reason)
          return "stopped"
        else
          error("fx_sched: join child finished with unexpected tag")
        end
      else
        task.parked = "join"
        task.join_target = child.id
        task.join_cancel_siblings = want_cancel
        child.joiners[#child.joiners + 1] = task.id
        return "parked"
      end

    ------------------------------------------------------------
    -- join_handles：按 handle 列表顺序收集结果
    ------------------------------------------------------------
    elseif req.kind == "join_handles" then
      local handles = req.handles
      assert(type(handles) == "table", "fx_sched: join_handles requires .handles")
      if #handles == 0 then
        task.answer = Coro.resume(task.answer, {})
      else
        local targets = {}
        local values = {}
        local done_n = 0
        local fail_now, stop_now
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
            cancel_fork_siblings(nursery, joined, task.id, "cancelled")
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

    ------------------------------------------------------------
    -- wait_event：事件总线 listen；无总线则走 handlers.wait_event
    ------------------------------------------------------------
    elseif req.kind == "wait_event" then
      local scheduler = opts.scheduler
      local listen = opts.listen
      if listen == nil and scheduler then
        listen = scheduler.listen
      end
      local unlisten = opts.unlisten
      if unlisten == nil and scheduler then
        unlisten = scheduler.unlisten
      end
      if type(listen) == "function" then
        local flag = { cancelled = false }
        local ev_handle
        ev_handle = listen(req.name, req.filter, function(payload)
          if flag.cancelled then
            return
          end
          if task.finished or not task.waiting then
            return
          end
          task.waiting = false
          task.waiting_event = false
          task.event_handle = nil
          task._event_flag = nil
          task._unlisten = nil
          if payload == nil then
            payload = true
          end
          task.answer = Coro.resume(task.answer, payload)
          if type(opts._pump) == "function" then
            opts._pump()
          end
        end)
        task.event_handle = ev_handle
        task._event_flag = flag
        task._unlisten = unlisten
        task.waiting = true
        task.waiting_event = true
        return "wait"
      else
        local handler = handlers.wait_event
        assert(handler, "fx_sched: no handler for kind=wait_event (and no listen)")
        local next_input = handler(req)
        task.answer = Coro.resume(task.answer, next_input)
      end

    ------------------------------------------------------------
    -- 其它效果（connect / click / 自定义 kind …）
    -- opts.async_kinds[kind]=true 时：handler(req, resume_cb)，异步兑现
    ------------------------------------------------------------
    else
      local handler = handlers[req.kind]
      assert(handler, "fx_sched: no handler for kind=" .. tostring(req.kind))
      local async_kinds = opts.async_kinds or handlers.__async_kinds
      local is_async = async_kinds and async_kinds[req.kind]
      if is_async then
        local flag = { cancelled = false }
        task._timer_flag = flag -- 复用取消旗标（无 timer 时仅作 cancelled）
        task.waiting = true
        handler(req, function(next_input)
          if flag.cancelled then
            return
          end
          if task.finished or not task.waiting then
            return
          end
          task.waiting = false
          task._timer_flag = nil
          task.answer = Coro.resume(task.answer, next_input)
          if type(opts._pump) == "function" then
            opts._pump()
          end
        end)
        return "wait"
      else
        local next_input = handler(req)
        task.answer = Coro.resume(task.answer, next_input)
      end
    end
  end

  if Coro.isDone(task.answer) then
    return "done"
  elseif Coro.isStopped(task.answer) then
    return "stopped"
  elseif Coro.isFailed(task.answer) then
    return "failed"
  end
  error("fx_sched: unexpected answer tag=" .. tostring(task.answer and task.answer.tag), 2)
end

------------------------------------------------------------
-- start_session / run_session
--   start_session → flow handle（可异步）；timer/事件回调里 pump
--   run_session：无 scheduler 时阻塞到终态（busy_wait）；有 scheduler 时
--     若已终态返回 result，否则返回 flow（由 GameSim.tick / advance 推进）
------------------------------------------------------------

local function normalize_sched_opts(opts)
  opts = opts or {}
  -- opts.game 可作为 Scheduler（GameSim 同时提供 now/schedule/cancel/listen）
  if opts.scheduler == nil and opts.game ~= nil then
    opts.scheduler = opts.game
  end
  return opts
end

function M.start_session(ma, handlers, opts)
  opts = normalize_sched_opts(opts)
  handlers = handlers or {}
  assert(ma ~= nil, "fx_sched.start_session: ma required")

  local nursery = new_nursery(handlers, opts)
  local root = alloc_task(nursery, ma)
  nursery.root_id = root.id

  local flow = {
    _is_flow = true,
    done = false,
    result = nil,
    nursery = nursery,
    root = root,
  }

  local function result_of_root()
    local a = root.answer
    if Coro.isDone(a) then
      return { ok = true, value = a.value }
    elseif Coro.isStopped(a) then
      local r = { ok = false, stopped = true, reason = a.reason }
      if root.fail_index then
        r.index = root.fail_index
      end
      return r
    elseif Coro.isFailed(a) then
      local r = { ok = false, failed = true, error = a.error }
      if root.fail_index then
        r.index = root.fail_index
      end
      return r
    end
    error("fx_sched: root not terminal")
  end

  local function settle_done()
    flow.done = true
    flow.result = result_of_root()
    return flow.result
  end

  local pumping = false

  local function pump()
    if flow.done then
      return flow.result
    end
    if pumping then
      -- 重入：timer 回调里又 pump；外层循环会继续扫
      return nil
    end
    pumping = true

    local function drive_runnables()
      local progressed = true
      while progressed do
        progressed = false
        local ids = {}
        for id, _ in pairs(nursery.tasks) do
          ids[#ids + 1] = id
        end
        table.sort(ids)
        for _, id in ipairs(ids) do
          local task = nursery.tasks[id]
          if task and is_runnable(task) then
            local st = drive_until_block(nursery, task)
            progressed = true
            if st == "done" or st == "stopped" or st == "failed" then
              on_task_terminal(nursery, task, st)
            end
          end
        end
        if root.finished then
          return true
        end
      end
      return root.finished
    end

    while not flow.done do
      if is_cancelled(opts.cancel) then
        cancel_all_unfinished(nursery, "cancelled")
        if not root.finished then
          root.answer = force_stop_task_answer(root.answer, "cancelled")
          mark_finished(root)
          root._terminal_handled = true
        end
        flow.done = true
        flow.result = { ok = false, stopped = true, reason = "cancelled" }
        pumping = false
        return flow.result
      end

      if drive_runnables() then
        pumping = false
        return settle_done()
      end

      -- 墙钟 deadline 等待（无外部 scheduler 时）
      local min_dl = nil
      local any_deadline = false
      local any_ext_wait = false -- scheduler timer / wait_event / async kind
      for _, task in pairs(nursery.tasks) do
        if not task.finished and task.waiting then
          if task.deadline then
            any_deadline = true
            if min_dl == nil or task.deadline < min_dl then
              min_dl = task.deadline
            end
          else
            any_ext_wait = true
          end
        end
      end

      if any_deadline and opts.scheduler == nil then
        local sleep_for = min_dl - now()
        if sleep_for > 0 then
          busy_wait(sleep_for)
        end
        local tnow = now()
        local due = {}
        for _, task in pairs(nursery.tasks) do
          if not task.finished and task.waiting and task.deadline
              and task.deadline <= tnow + 1e-9 then
            due[#due + 1] = task
          end
        end
        if #due == 0 then
          local best
          for _, task in pairs(nursery.tasks) do
            if not task.finished and task.waiting and task.deadline then
              if best == nil or task.deadline < best.deadline then
                best = task
              end
            end
          end
          if best then
            due[1] = best
          end
        end
        for _, task in ipairs(due) do
          task.waiting = false
          task.deadline = nil
          if opts.verbose_wait then
            print(string.format("[fx.session] task#%d wait done", task.id))
          end
          task.answer = Coro.resume(task.answer, true)
          local st = drive_until_block(nursery, task)
          if st == "done" or st == "stopped" or st == "failed" then
            on_task_terminal(nursery, task, st)
          end
        end
        -- 继续 while，再 drive
      elseif any_ext_wait or any_deadline then
        -- 有外部 scheduler：阻塞在 timer/事件上，交还控制权
        pumping = false
        return nil
      else
        local any_runnable = false
        local any_parked = false
        for _, task in pairs(nursery.tasks) do
          if is_runnable(task) then
            any_runnable = true
          end
          if not task.finished and task.parked then
            any_parked = true
          end
        end
        if any_runnable then
          -- 再推一轮
        elseif any_parked then
          local drove = false
          for _, task in pairs(nursery.tasks) do
            if is_runnable(task) then
              drove = true
              break
            end
          end
          if not drove then
            pumping = false
            error("fx_sched: deadlock — parked tasks with no runnable children")
          end
        else
          pumping = false
          error("fx_sched: deadlock — unfinished tasks not waiting")
        end
      end
    end

    pumping = false
    return flow.result
  end

  flow.pump = pump
  flow.cancel = function(reason)
    reason = reason or "cancelled"
    if flow.done then
      return flow.result
    end
    cancel_all_unfinished(nursery, reason)
    if not root.finished then
      root.answer = force_stop_task_answer(root.answer, reason)
      mark_finished(root)
      root._terminal_handled = true
    end
    flow.done = true
    flow.result = { ok = false, stopped = true, reason = reason }
    return flow.result
  end

  function flow.is_done()
    return flow.done
  end

  opts._pump = pump
  nursery.opts = opts -- 确保 clear_task_waits 见到 _pump/scheduler
  pump()
  return flow
end

function M.run_session(ma, handlers, opts)
  opts = normalize_sched_opts(opts)
  local flow = M.start_session(ma, handlers, opts)
  if flow.done then
    return flow.result
  end
  if opts.scheduler ~= nil then
    -- 异步：返回 flow handle，由外部 tick / advance 推进
    return flow
  end
  -- 无 scheduler：start_session 的 pump 应已通过 busy_wait 跑完
  -- 若仍未完成（理论上不应），再 pump 直到 done
  while not flow.done do
    local r = flow.pump()
    if r ~= nil then
      return r
    end
    error("fx_sched.run_session: blocked without scheduler")
  end
  return flow.result
end

------------------------------------------------------------
-- run_parallel：WhenAll / WhenAny 顶层（经 session）
------------------------------------------------------------

function M.run_parallel(tasks, handlers, opts, mode)
  opts = opts or {}
  mode = mode or "all"
  assert(type(tasks) == "table", "fx_sched.run_parallel: tasks must be array")
  assert(mode == "all" or mode == "any", "fx_sched.run_parallel: mode must be all|any")
  handlers = handlers or {}

  local n = #tasks
  if n == 0 then
    if mode == "all" then
      return { ok = true, values = {} }
    end
    return { ok = false, failed = true, error = "when_any: empty task list" }
  end

  local body
  if mode == "all" then
    body = Coro.yield({ kind = "when_all", tasks = tasks }) >> function(values)
      return Cont.unit(values)
    end
  else
    body = Coro.yield({ kind = "when_any", tasks = tasks }) >> function(winner)
      return Cont.unit(winner)
    end
  end

  local r = M.run_session(body, handlers, opts)
  -- 异步 flow：原样返回，由调用方 tick
  if type(r) == "table" and r._is_flow then
    return r
  end
  if not r.ok then
    return r
  end
  if mode == "all" then
    return { ok = true, values = r.value }
  end
  -- any：r.value = { value=, index= }
  local w = r.value
  return { ok = true, value = w.value, index = w.index }
end

return M
