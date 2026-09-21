-- fx_sched_session.lua — start_session / run_session / run_parallel
local Coro = require("coro")
local Cont = require("cont")

local Mod = {}

function Mod.install(S)

function S.normalize_sched_opts(opts)
  opts = opts or {}
  -- opts.game 可作为 Scheduler（GameSim 同时提供 S.now/schedule/cancel/listen）
  if opts.scheduler == nil and opts.game ~= nil then
    opts.scheduler = opts.game
  end
  return opts
end

function S.result_from_terminal_answer(answer)
  if Coro.isDone(answer) then
    return { ok = true, value = answer.value }
  elseif Coro.isAborted(answer) then
    return { ok = false, aborted = true, reason = answer.reason }
  elseif Coro.isStopped(answer) then
    return { ok = false, stopped = true, reason = answer.reason }
  elseif Coro.isFailed(answer) then
    return { ok = false, failed = true, error = answer.error }
  end
  error("fx_sched: expected terminal Answer", 2)
end

function S.emit_settle_traces(opts, root_id, result)
  if result.ok then
    S.emit_trace(opts, { type = "done", root_id = root_id, value = result.value })
  elseif result.aborted then
    S.emit_trace(opts, { type = "aborted", root_id = root_id, reason = result.reason })
  elseif result.stopped then
    S.emit_trace(opts, { type = "stopped", root_id = root_id, reason = result.reason })
  elseif result.failed then
    S.emit_trace(opts, { type = "failed", root_id = root_id, error = result.error })
  end
end

function S.start_session(ma, handlers, opts)
  opts = S.normalize_sched_opts(opts)
  handlers = handlers or {}
  assert(ma ~= nil, "fx_sched.start_session: ma required")

  -- 同步快路径：Coro.start 立刻终态（未 Yield）→ 跳过 nursery / session 循环。
  -- 纯 Cont.unit/bind/seq、即时 stop/abort/fail、已跑完的 finally/iquit 皆适用；
  -- 一旦 Yielded（wait/fork/…）则注入 pre_answer 走既有 session，语义不变。
  local answer = Coro.start(ma)
  if not Coro.isYielded(answer) then
    local root_id = 1
    local deadline_abs = nil
    if opts.deadline ~= nil then
      assert(type(opts.deadline) == "number",
        "fx_sched: opts.deadline must be number (absolute clock)")
      deadline_abs = opts.deadline
    elseif opts.timeout ~= nil then
      assert(type(opts.timeout) == "number" and opts.timeout >= 0,
        "fx_sched: opts.timeout must be number >= 0 (seconds)")
      deadline_abs = S.clock_now(opts) + opts.timeout
    end
    S.emit_trace(opts, {
      type = "flow_start",
      root_id = root_id,
      deadline_abs = deadline_abs,
    })
    local result
    -- 与 pump 一致：cancel 优先于已算完的终态（Cont 已在 start 时求值完毕）
    if S.is_cancelled(opts.cancel) then
      result = { ok = false, stopped = true, reason = "cancelled" }
      S.emit_trace(opts, { type = "cancel", root_id = root_id, reason = "cancelled" })
      S.emit_trace(opts, { type = "stopped", root_id = root_id, reason = "cancelled" })
    else
      result = S.result_from_terminal_answer(answer)
      S.emit_settle_traces(opts, root_id, result)
    end
    return S.make_settled_flow(result)
  end

  local nursery = S.new_nursery(handlers, opts)
  local root = S.alloc_task(nursery, ma, answer)
  nursery.root_id = root.id

  -- session 级截止：opts.deadline（绝对）或 opts.timeout（相对秒）
  local t0 = S.clock_now(opts)
  if opts.deadline ~= nil then
    assert(type(opts.deadline) == "number",
      "fx_sched: opts.deadline must be number (absolute clock)")
    S.apply_deadline_abs(root, opts.deadline)
  elseif opts.timeout ~= nil then
    assert(type(opts.timeout) == "number" and opts.timeout >= 0,
      "fx_sched: opts.timeout must be number >= 0 (seconds)")
    S.apply_deadline_abs(root, t0 + opts.timeout)
  end
  local session_on_timeout = opts.on_timeout
  if session_on_timeout == nil then
    session_on_timeout = "timeout"
  end
  if root.deadline_abs ~= nil and opts.scheduler == nil then
    nursery.session_deadline = root.deadline_abs
    nursery.session_on_timeout = session_on_timeout
  end

  local flow = {
    _is_flow = true,
    done = false,
    result = nil,
    nursery = nursery,
    root = root,
    suspended = false,
    _deferred = {},
  }
  opts._flow = flow

  --- 挂起本 flow：已登记的 wait/timer/poll 到期不 resume，推迟到 resume()
  function flow.suspend()
    if flow.done then
      return
    end
    flow.suspended = true
  end

  --- 恢复：兑现挂起期间到期的回调，再 pump
  function flow.resume()
    if flow.done then
      return flow.result
    end
    if not flow.suspended then
      return nil
    end
    flow.suspended = false
    local deferred = flow._deferred or {}
    flow._deferred = {}
    for i = 1, #deferred do
      deferred[i]()
      if flow.done then
        return flow.result
      end
    end
    if type(opts._pump) == "function" then
      opts._pump()
    end
    return flow.result
  end

  function flow.is_suspended()
    return flow.suspended == true
  end

  S.emit_trace(opts, {
    type = "flow_start",
    root_id = root.id,
    deadline_abs = root.deadline_abs,
  })

  local function clear_deadline_watchdog()
    if flow._deadline_flag then
      flow._deadline_flag.cancelled = true
      flow._deadline_flag = nil
    end
    if flow._deadline_handle ~= nil then
      local scheduler = opts.scheduler
      if scheduler and type(scheduler.cancel) == "function" then
        scheduler.cancel(flow._deadline_handle)
      end
      flow._deadline_handle = nil
    end
    nursery.session_deadline = nil
  end

  local function result_of_root()
    local a = root.answer
    if Coro.isDone(a) then
      return { ok = true, value = a.value }
    elseif Coro.isAborted(a) then
      local r = { ok = false, aborted = true, reason = a.reason }
      if root.fail_index then
        r.index = root.fail_index
      end
      return r
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
    clear_deadline_watchdog()
    flow.done = true
    flow.result = result_of_root()
    local r = flow.result
    if r.ok then
      S.emit_trace(opts, { type = "done", root_id = root.id, value = r.value })
    elseif r.aborted then
      S.emit_trace(opts, { type = "aborted", root_id = root.id, reason = r.reason })
    elseif r.stopped then
      S.emit_trace(opts, { type = "stopped", root_id = root.id, reason = r.reason })
    elseif r.failed then
      S.emit_trace(opts, { type = "failed", root_id = root.id, error = r.error })
    end
    S.notify_flow_proxy_joiners(flow)
    return flow.result
  end

  -- session / 继承截止触发：子树 Stopped（finally），根 Failed(on_timeout)
  local function fire_session_deadline()
    if flow.done then
      return flow.result
    end
    S.emit_trace(opts, {
      type = "cancel",
      root_id = root.id,
      reason = "deadline",
    })
    clear_deadline_watchdog()
    -- 先停所有非根未完成任务
    local ids = {}
    for id, t in pairs(nursery.tasks) do
      if t and not t.finished and id ~= root.id then
        ids[#ids + 1] = id
      end
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
        t.answer = S.force_stop_task_answer(t.answer, "cancelled")
        if not t._terminal_handled then
          S.on_task_terminal(nursery, t, "stopped")
        else
          S.mark_finished(t)
        end
      end
    end
    if not root.finished then
      S.clear_task_waits(root)
      root.answer = Coro.Failed(session_on_timeout)
      S.mark_finished(root)
      root._terminal_handled = true
    end
    flow.done = true
    flow.result = { ok = false, failed = true, error = session_on_timeout }
    S.emit_trace(opts, {
      type = "failed",
      root_id = root.id,
      error = session_on_timeout,
    })
    S.notify_flow_proxy_joiners(flow)
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
          if task and S.is_runnable(task) then
            local st = S.drive_until_block(nursery, task)
            progressed = true
            if st == "done" or st == "stopped" or st == "aborted" or st == "failed" then
              S.on_task_terminal(nursery, task, st)
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
      if flow.suspended then
        pumping = false
        return nil
      end
      if S.is_cancelled(opts.cancel) then
        clear_deadline_watchdog()
        S.emit_trace(opts, { type = "cancel", root_id = root.id, reason = "cancelled" })
        S.cancel_all_unfinished(nursery, "cancelled")
        if not root.finished then
          root.answer = S.force_stop_task_answer(root.answer, "cancelled")
          S.mark_finished(root)
          root._terminal_handled = true
        end
        flow.done = true
        flow.result = { ok = false, stopped = true, reason = "cancelled" }
        S.emit_trace(opts, { type = "stopped", root_id = root.id, reason = "cancelled" })
        S.notify_flow_proxy_joiners(flow)
        pumping = false
        return flow.result
      end

      if drive_runnables() then
        pumping = false
        return settle_done()
      end

      -- 墙钟 deadline / wait_until 等待（无外部 scheduler 时）
      local min_dl = nil
      local any_deadline = false
      local any_ext_wait = false -- scheduler timer / wait_event / async kind / poll
      local any_until = false
      for _, task in pairs(nursery.tasks) do
        if not task.finished and task.waiting then
          if task.deadline then
            any_deadline = true
            if min_dl == nil or task.deadline < min_dl then
              min_dl = task.deadline
            end
          elseif task._wait_until_pred then
            any_until = true
            any_deadline = true -- 复用忙等分支
            local nxt = task._wait_until_next or S.now()
            if min_dl == nil or nxt < min_dl then
              min_dl = nxt
            end
          else
            any_ext_wait = true
          end
        end
        -- 跨 session proxy_join：外部 flow 终态时 notify，算 ext wait
        if not task.finished and task.parked == "proxy_flow" then
          any_ext_wait = true
        end
      end
      if nursery.session_deadline ~= nil then
        any_deadline = true
        if min_dl == nil or nursery.session_deadline < min_dl then
          min_dl = nursery.session_deadline
        end
      end

      if any_deadline and opts.scheduler == nil then
        local sleep_for = min_dl - S.now()
        if sleep_for > 0 then
          S.busy_wait(sleep_for)
        end
        local tnow = S.now()
        if nursery.session_deadline ~= nil
            and nursery.session_deadline <= tnow + 1e-9 then
          pumping = false
          return fire_session_deadline()
        end
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
          local st = S.drive_until_block(nursery, task)
          if st == "done" or st == "stopped" or st == "aborted" or st == "failed" then
            S.on_task_terminal(nursery, task, st)
          end
        end
        -- wait_until（无 scheduler 演示路径）：到点则 poll
        for _, task in pairs(nursery.tasks) do
          if not task.finished and task.waiting and task._wait_until_pred
              and (task._wait_until_next or 0) <= tnow + 1e-9 then
            local ok, result = pcall(task._wait_until_pred)
            if not ok then
              S.clear_task_waits(task)
              task.answer = Coro.Failed(result)
              S.on_task_terminal(nursery, task, "failed")
            elseif result then
              task.waiting = false
              task._wait_until_pred = nil
              task._wait_until_interval = nil
              task._wait_until_next = nil
              task.answer = Coro.resume(task.answer, result)
              local st = S.drive_until_block(nursery, task)
              if st == "done" or st == "stopped" or st == "aborted" or st == "failed" then
                S.on_task_terminal(nursery, task, st)
              end
            else
              local iv = task._wait_until_interval or 0
              task._wait_until_next = tnow + (iv > 0 and iv or 0.001)
            end
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
          if S.is_runnable(task) then
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
            if S.is_runnable(task) then
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
    clear_deadline_watchdog()
    S.emit_trace(opts, { type = "cancel", root_id = root.id, reason = reason })
    S.cancel_all_unfinished(nursery, reason)
    if not root.finished then
      root.answer = S.force_stop_task_answer(root.answer, reason)
      S.mark_finished(root)
      root._terminal_handled = true
    end
    flow.done = true
    flow.result = { ok = false, stopped = true, reason = reason }
    S.emit_trace(opts, { type = "stopped", root_id = root.id, reason = reason })
    S.notify_flow_proxy_joiners(flow)
    return flow.result
  end

  function flow.is_done()
    return flow.done
  end

  opts._pump = pump
  nursery.opts = opts -- 确保 S.clear_task_waits 见到 _pump/scheduler
  S.attach_flow_proxy_method(flow)

  -- 有 scheduler 时挂 deadline 看门狗（游戏时间）
  if root.deadline_abs ~= nil and opts.scheduler ~= nil then
    local delay = root.deadline_abs - S.clock_now(opts)
    if delay < 0 then
      delay = 0
    end
    local flag = { cancelled = false }
    flow._deadline_flag = flag
    flow._deadline_handle = opts.scheduler.schedule(delay, function()
      if flag.cancelled or flow.done then
        return
      end
      fire_session_deadline()
      if type(opts._pump) == "function" then
        opts._pump()
      end
    end)
  end

  pump()
  return flow
end

function S.run_session(ma, handlers, opts)
  opts = S.normalize_sched_opts(opts)
  local flow = S.start_session(ma, handlers, opts)
  if flow.done then
    return flow.result
  end
  if opts.scheduler ~= nil then
    -- 异步：返回 flow handle，由外部 tick / advance 推进
    return flow
  end
  -- 无 scheduler：S.start_session 的 pump 应已通过 S.busy_wait 跑完
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

function S.run_parallel(tasks, handlers, opts, mode)
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

  local r = S.run_session(body, handlers, opts)
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


  function S.export_session(M)
    M.start_session = S.start_session
    M.run_session = S.run_session
    M.run_parallel = S.run_parallel
  end

end

return Mod
