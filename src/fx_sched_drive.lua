-- fx_sched_drive.lua — drive_until_block（yield 分派）+ 共享 wait/join 辅助
local Coro = require("coro")
local Registry = require("fx_registry")

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

function S.drive_until_block(nursery, task)
  local handlers = nursery.handlers
  local opts = nursery.opts

  while Coro.isYielded(task.answer) do
    if S.is_cancelled(opts.cancel) then
      S.clear_task_waits(task)
      task.answer = S.force_stop_task_answer(task.answer, "cancelled")
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
      S.emit_trace(opts, { type = "yield", task_id = task.id, kind = "wait", seconds = secs })
      local scheduler = opts.scheduler
      -- 外部 Scheduler：登记 timer，不 S.busy_wait；回调里 resume + pump
      if scheduler ~= nil then
        S.arm_scheduler_timer(task, opts, secs, function(s, cb)
          return scheduler.schedule(s, cb)
        end, "wait")
        if opts.verbose_wait then
          print(string.format("[fx.session] task#%d wait %.3fs (scheduler)", task.id, secs))
        end
        return "wait"
      end
      -- 多任务（含 fork 子任务）走时间轮；单任务走 handlers.wait（兼容瞬时 mock）
      if S.live_count(nursery) > 1 then
        task.deadline = S.now() + secs
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
    -- wait_real：墙钟等待（opt-in；默认 Failed）
    --   scheduler.schedule_real → 宿主 realtime
    --   opts.allow_real_time → S.busy_wait
    --   否则 → Failed{tag=wait_real_unsupported}
    ------------------------------------------------------------
    elseif req.kind == "wait_real" then
      local secs = req.seconds or 0
      S.emit_trace(opts, { type = "yield", task_id = task.id, kind = "wait_real", seconds = secs })
      local scheduler = opts.scheduler
      if scheduler ~= nil and type(scheduler.schedule_real) == "function" then
        S.arm_scheduler_timer(task, opts, secs, function(s, cb)
          return scheduler.schedule_real(s, cb)
        end, "wait_real")
        if opts.verbose_wait then
          print(string.format("[fx.session] task#%d wait_real %.3fs (schedule_real)", task.id, secs))
        end
        return "wait"
      elseif opts.allow_real_time then
        if opts.verbose_wait then
          print(string.format("[fx.session] task#%d wait_real %.3fs (allow_real_time busy)", task.id, secs))
        end
        S.busy_wait(secs)
        S.emit_trace(opts, { type = "resume", task_id = task.id, kind = "wait_real" })
        task.answer = Coro.resume(task.answer, true)
      else
        local err = {
          tag = "wait_real_unsupported",
          message = "wait_real unsupported",
          effect_kind = "wait_real",
        }
        S.emit_trace(opts, {
          type = "failed",
          task_id = task.id,
          error = err,
          kind = "wait_real",
        })
        task.answer = Coro.Failed(err)
        return "failed"
      end

    ------------------------------------------------------------
    -- when_all / when_any（同 nursery 结构化并行）
    ------------------------------------------------------------
    elseif req.kind == "when_all" or req.kind == "when_any" then
      S.emit_trace(opts, { type = "yield", task_id = task.id, kind = req.kind })
      local mode = (req.kind == "when_any") and "any" or "all"
      local st = S.start_group(nursery, task, req, mode)
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
      local st = S.start_timeout_race(nursery, task, req)
      if st == "parked" then
        return "parked"
      end

    ------------------------------------------------------------
    -- supervise：子失败时按策略重启
    ------------------------------------------------------------
    elseif req.kind == "supervise" then
      S.emit_trace(opts, { type = "yield", task_id = task.id, kind = "supervise" })
      local st = S.start_supervise(nursery, task, req)
      if st == "parked" then
        return "parked"
      end

    ------------------------------------------------------------
    -- fork：启动子 Cont，立刻把 handle 还给父任务
    ------------------------------------------------------------
    elseif req.kind == "fork" then
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

    ------------------------------------------------------------
    -- join：等单个 handle
    ------------------------------------------------------------
    elseif req.kind == "join" then
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

    ------------------------------------------------------------
    -- lane：命名 fork（session.lanes[name] = child.id）
    ------------------------------------------------------------
    elseif req.kind == "lane" then
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

    ------------------------------------------------------------
    -- lane_join：按名 join（复用 fork join 语义）
    ------------------------------------------------------------
    elseif req.kind == "lane_join" then
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
        if Coro.isDone(child.answer) then
          task.answer = Coro.resume(task.answer, child.result)
          if want_cancel then
            S.cancel_fork_siblings(nursery, { [child.id] = true }, task.id, "cancelled")
          end
        elseif Coro.isFailed(child.answer) then
          task.answer = Coro.Failed(child.answer.error)
          return "failed"
        elseif Coro.isAborted(child.answer) then
          task.answer = Coro.Aborted(child.answer.reason)
          return "aborted"
        elseif Coro.isStopped(child.answer) then
          task.answer = Coro.Stopped(child.answer.reason)
          return "stopped"
        else
          error("fx_sched: lane_join child finished with unexpected tag")
        end
      else
        task.parked = "join"
        task.join_target = child.id
        task.join_cancel_siblings = want_cancel
        child.joiners[#child.joiners + 1] = task.id
        return "parked"
      end

    ------------------------------------------------------------
    -- lane_stop / lane_abort：按名停/中止
    ------------------------------------------------------------
    elseif req.kind == "lane_stop" or req.kind == "lane_abort" then
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

    ------------------------------------------------------------
    -- proxy_join：等 proxy 目标（复用 joiners；flow 可跨 session）
    ------------------------------------------------------------
    elseif req.kind == "proxy_join" then
      local proxy = req.proxy
      assert(type(proxy) == "table" and proxy._is_proxy,
        "fx_sched: proxy_join requires proxy")
      local want_cancel = not not req.cancel_siblings
      local stop_host = not not proxy.stop_host_when_stop

      if proxy.flow ~= nil then
        local fl = proxy.flow
        S.emit_trace(opts, {
          type = "join",
          task_id = task.id,
          proxy = "flow",
        })
        -- 同 session：join root
        if fl.nursery == nursery and fl.root ~= nil then
          local child = fl.root
          if child.finished then
            if Coro.isDone(child.answer) then
              task.answer = Coro.resume(task.answer, child.result)
              if want_cancel then
                S.cancel_fork_siblings(nursery, { [child.id] = true }, task.id, "cancelled")
              end
            elseif Coro.isFailed(child.answer) then
              task.answer = Coro.Failed(child.answer.error)
              return "failed"
            elseif Coro.isAborted(child.answer) then
              task.answer = Coro.Aborted(child.answer.reason)
              return "aborted"
            elseif Coro.isStopped(child.answer) then
              task.answer = Coro.Stopped(child.answer.reason)
              return "stopped"
            else
              error("fx_sched: proxy_join flow root unexpected tag")
            end
          else
            task.parked = "join"
            task.join_target = child.id
            task.join_cancel_siblings = want_cancel
            if stop_host then
              task.proxy_stop_host = true
            end
            child.joiners[#child.joiners + 1] = task.id
            return "parked"
          end
        elseif fl.done then
          local r = fl.result
          if r == nil then
            task.answer = Coro.Failed({ tag = "proxy_unknown", why = "flow_no_result" })
            return "failed"
          end
          if r.ok then
            task.answer = Coro.resume(task.answer, r.value)
          elseif r.aborted then
            task.answer = Coro.Aborted(r.reason)
            return "aborted"
          elseif r.stopped then
            task.answer = Coro.Stopped(r.reason)
            return "stopped"
          elseif r.failed then
            task.answer = Coro.Failed(r.error)
            return "failed"
          else
            task.answer = Coro.Failed({ tag = "proxy_unknown", why = "flow_bad_result" })
            return "failed"
          end
        else
          -- 跨 session：挂到 flow._proxy_joiners
          if fl._proxy_joiners == nil then
            fl._proxy_joiners = {}
          end
          task.parked = "proxy_flow"
          task.proxy_host_flow = fl
          if stop_host then
            task.proxy_stop_host = true
          end
          fl._proxy_joiners[#fl._proxy_joiners + 1] = {
            nursery = nursery,
            task_id = task.id,
          }
          return "parked"
        end
      else
        local child, kind = S.resolve_proxy_target(nursery, proxy)
        if kind == "unknown" or child == nil then
          task.answer = Coro.Failed({
            tag = "proxy_unknown",
            name = proxy.name,
            id = proxy.id,
          })
          return "failed"
        end
        S.emit_trace(opts, {
          type = "join",
          task_id = task.id,
          target_id = child.id,
          proxy = kind,
        })
        if child.finished then
          if Coro.isDone(child.answer) then
            task.answer = Coro.resume(task.answer, child.result)
            if want_cancel then
              S.cancel_fork_siblings(nursery, { [child.id] = true }, task.id, "cancelled")
            end
          elseif Coro.isFailed(child.answer) then
            task.answer = Coro.Failed(child.answer.error)
            return "failed"
          elseif Coro.isAborted(child.answer) then
            task.answer = Coro.Aborted(child.answer.reason)
            return "aborted"
          elseif Coro.isStopped(child.answer) then
            task.answer = Coro.Stopped(child.answer.reason)
            return "stopped"
          else
            error("fx_sched: proxy_join child finished with unexpected tag")
          end
        else
          task.parked = "join"
          task.join_target = child.id
          task.join_cancel_siblings = want_cancel
          if stop_host then
            task.proxy_stop_host = true
          end
          child.joiners[#child.joiners + 1] = task.id
          return "parked"
        end
      end

    ------------------------------------------------------------
    -- proxy_stop / proxy_abort：停/中止 proxy 目标
    ------------------------------------------------------------
    elseif req.kind == "proxy_stop" or req.kind == "proxy_abort" then
      local proxy = req.proxy
      assert(type(proxy) == "table" and proxy._is_proxy,
        "fx_sched: " .. req.kind .. " requires proxy")
      local mode = (req.kind == "proxy_abort") and "abort" or "stop"
      local reason = req.reason
      if reason == nil then
        reason = (mode == "abort") and "proxy_abort" or "proxy_stop"
      end
      S.emit_trace(opts, {
        type = "cancel",
        task_id = task.id,
        proxy = true,
        mode = mode,
      })
      local ok = false
      if proxy.flow ~= nil then
        local fl = proxy.flow
        if not fl.done then
          if mode == "abort" and fl.root and not fl.root.finished then
            -- 中止根任务并 settle flow
            local root = fl.root
            local n = fl.nursery
            if n then
              S.cancel_descendants(n, root.id, reason)
              S.clear_task_waits(root)
              if Coro.isYielded(root.answer) and type(root.answer.abort) == "function" then
                root.answer.abort(reason)
              end
              root.answer = Coro.Aborted(reason)
              S.mark_finished(root)
              root._terminal_handled = true
            end
            fl.done = true
            fl.result = { ok = false, aborted = true, reason = reason }
            S.notify_flow_proxy_joiners(fl)
            ok = true
          elseif type(fl.cancel) == "function" then
            fl.cancel(reason)
            ok = true
          end
        end
      else
        local child, kind = S.resolve_proxy_target(nursery, proxy)
        if child ~= nil then
          ok = S.stop_task(nursery, child, mode, reason)
        end
      end
      task.answer = Coro.resume(task.answer, ok)

    ------------------------------------------------------------
    -- wait_event：事件总线 listen；无总线则走 handlers.wait_event
    ------------------------------------------------------------
    elseif req.kind == "wait_event" then
      S.emit_trace(opts, {
        type = "yield",
        task_id = task.id,
        kind = "wait_event",
        name = req.name,
      })
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
          S.when_flow_active(opts, function()
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
        end)
        task.event_handle = ev_handle
        task._event_flag = flag
        task._unlisten = unlisten
        task.waiting = true
        task.waiting_event = true
        return "wait"
      else
        local handler = handlers.wait_event
        if handler == nil then
          local err = Registry.unknown_error("wait_event")
          S.emit_trace(opts, {
            type = "failed",
            task_id = task.id,
            error = err,
            kind = "wait_event",
          })
          task.answer = Coro.Failed(err)
          return "failed"
        end
        local next_input = handler(req)
        S.emit_trace(opts, {
          type = "resume",
          task_id = task.id,
          kind = "wait_event",
        })
        task.answer = Coro.resume(task.answer, next_input)
      end

    ------------------------------------------------------------
    -- wait_until：每 tick / interval poll pred；真值 resume
    ------------------------------------------------------------
    elseif req.kind == "wait_until" then
      local pred = req.pred
      assert(type(pred) == "function", "fx_sched: wait_until requires .pred function")
      local interval = req.interval or 0
      assert(type(interval) == "number" and interval >= 0,
        "fx_sched: wait_until interval must be >= 0")
      S.emit_trace(opts, {
        type = "yield",
        task_id = task.id,
        kind = "wait_until",
        interval = interval,
      })
      local scheduler = opts.scheduler

      local function resume_until(result)
        S.when_flow_active(opts, function()
          if task.finished or not task.waiting then
            return
          end
          task.waiting = false
          task.timer_handle = nil
          task._timer_flag = nil
          task._wait_until_pred = nil
          task._wait_until_interval = nil
          task._wait_until_next = nil
          S.emit_trace(opts, {
            type = "resume",
            task_id = task.id,
            kind = "wait_until",
          })
          task.answer = Coro.resume(task.answer, result)
          if type(opts._pump) == "function" then
            opts._pump()
          end
        end)
      end

      local function fail_until(err)
        S.when_flow_active(opts, function()
          if task.finished then
            return
          end
          S.clear_task_waits(task)
          task.answer = Coro.Failed(err)
          if type(opts._pump) == "function" then
            opts._pump()
          end
        end)
      end

      -- 立刻试一次（同帧可完成）
      do
        local ok, result = pcall(pred)
        if not ok then
          task.answer = Coro.Failed(result)
          return "failed"
        end
        if result then
          task.answer = Coro.resume(task.answer, result)
          -- 继续 drive 循环
        else
          if scheduler ~= nil and type(scheduler.schedule_poll) == "function" then
            local flag = { cancelled = false }
            local handle = scheduler.schedule_poll(pred, function(v)
              if flag.cancelled then
                return
              end
              resume_until(v)
            end, {
              interval = interval,
              on_error = function(err)
                if flag.cancelled then
                  return
                end
                fail_until(err)
              end,
            })
            task.timer_handle = handle
            task._timer_flag = flag
            task.waiting = true
            return "wait"
          elseif scheduler ~= nil then
            -- 无 schedule_poll：用 schedule 自再预约模拟（VirtualClock 等）
            local flag = { cancelled = false }
            local handle_box = { h = nil }
            local function arm(delay)
              handle_box.h = scheduler.schedule(delay, function()
                if flag.cancelled then
                  return
                end
                if task.finished or not task.waiting then
                  return
                end
                local ok, result = pcall(pred)
                if not ok then
                  fail_until(result)
                  return
                end
                if result then
                  resume_until(result)
                else
                  local d = interval
                  if d <= 0 then
                    d = 0
                  end
                  arm(d)
                  task.timer_handle = handle_box.h
                end
              end)
              task.timer_handle = handle_box.h
            end
            task._timer_flag = flag
            task.waiting = true
            arm(0)
            return "wait"
          else
            -- 演示回退：单任务忙轮询；多任务挂到墙钟循环
            if S.live_count(nursery) > 1 then
              task._wait_until_pred = pred
              task._wait_until_interval = interval
              task._wait_until_next = S.now() + (interval > 0 and interval or 0)
              task.waiting = true
              return "wait"
            else
              local step = interval
              if step <= 0 then
                step = 0.001
              end
              while true do
                if S.is_cancelled(opts.cancel) then
                  task.answer = S.force_stop_task_answer(task.answer, "cancelled")
                  return "stopped"
                end
                S.busy_wait(step)
                local ok, result = pcall(pred)
                if not ok then
                  task.answer = Coro.Failed(result)
                  return "failed"
                end
                if result then
                  task.answer = Coro.resume(task.answer, result)
                  break
                end
              end
            end
          end
        end
      end

    ------------------------------------------------------------
    -- chan_send / chan_recv / chan_close（有界 mailbox）
    ------------------------------------------------------------
    elseif req.kind == "chan_send" then
      local ch = S.assert_chan_req(req.chan, "chan_send")
      local value = req.value
      S.emit_trace(opts, { type = "yield", task_id = task.id, kind = "chan_send" })
      if ch.closed then
        task.answer = Coro.Failed(S.chan_closed_err("send"))
        return "failed"
      end
      local delivered = false
      -- 优先交给等待中的 recv（会合 / 直送）
      while #ch.recv_q > 0 do
        local w = table.remove(ch.recv_q, 1)
        if not (w.flag and w.flag.cancelled) then
          S.settle_chan_waiter(w, "ok", value)
          task.answer = Coro.resume(task.answer, true)
          S.emit_trace(opts, { type = "resume", task_id = task.id, kind = "chan_send" })
          delivered = true
          break
        end
      end
      if not delivered then
        if #ch.buf < ch.capacity then
          ch.buf[#ch.buf + 1] = value
          task.answer = Coro.resume(task.answer, true)
          S.emit_trace(opts, { type = "resume", task_id = task.id, kind = "chan_send" })
        else
          local w = { task = task, value = value, flag = { cancelled = false } }
          ch.send_q[#ch.send_q + 1] = w
          task._chan_waiter = w
          task._chan = ch
          task.waiting = true
          return "wait"
        end
      end

    elseif req.kind == "chan_recv" then
      local ch = S.assert_chan_req(req.chan, "chan_recv")
      S.emit_trace(opts, { type = "yield", task_id = task.id, kind = "chan_recv" })
      if #ch.buf > 0 then
        local value = table.remove(ch.buf, 1)
        S.admit_senders(ch)
        task.answer = Coro.resume(task.answer, value)
        S.emit_trace(opts, { type = "resume", task_id = task.id, kind = "chan_recv" })
      else
        -- 缓冲空：尝试会合 send 等待方
        local matched = false
        while #ch.send_q > 0 do
          local w = table.remove(ch.send_q, 1)
          if not (w.flag and w.flag.cancelled) then
            local value = w.value
            S.settle_chan_waiter(w, "ok", true)
            task.answer = Coro.resume(task.answer, value)
            S.emit_trace(opts, { type = "resume", task_id = task.id, kind = "chan_recv" })
            matched = true
            break
          end
        end
        if not matched then
          if ch.closed then
            task.answer = Coro.Failed(S.chan_closed_err("recv"))
            return "failed"
          end
          local w = { task = task, flag = { cancelled = false } }
          ch.recv_q[#ch.recv_q + 1] = w
          task._chan_waiter = w
          task._chan = ch
          task.waiting = true
          return "wait"
        end
      end

    elseif req.kind == "chan_close" then
      local ch = S.assert_chan_req(req.chan, "chan_close")
      S.emit_trace(opts, { type = "yield", task_id = task.id, kind = "chan_close" })
      S.close_channel(ch)
      task.answer = Coro.resume(task.answer, true)
      S.emit_trace(opts, { type = "resume", task_id = task.id, kind = "chan_close" })

    ------------------------------------------------------------
    -- 其它效果（connect / click / 自定义 kind …）
    -- opts.async_kinds[kind]=true 时：handler(req, resume_cb)，异步兑现
    ------------------------------------------------------------
    else
      local handler = handlers[req.kind]
      if handler == nil then
        -- 再查全局注册表（handlers 合并遗漏时兜底）
        local ent = Registry.get(req.kind)
        if ent then
          handler = ent.handler
          local async_kinds = opts.async_kinds or handlers.__async_kinds or {}
          if ent.async then
            async_kinds = async_kinds or {}
            async_kinds[req.kind] = true
            opts.async_kinds = async_kinds
          end
        end
      end
      if handler == nil then
        local err = Registry.unknown_error(req.kind)
        S.emit_trace(opts, {
          type = "failed",
          task_id = task.id,
          error = err,
          kind = req.kind,
        })
        task.answer = Coro.Failed(err)
        return "failed"
      end
      S.emit_trace(opts, {
        type = "yield",
        task_id = task.id,
        kind = req.kind,
      })
      local async_kinds = opts.async_kinds or handlers.__async_kinds
      local is_async = async_kinds and async_kinds[req.kind]
      if is_async then
        local flag = { cancelled = false }
        task._timer_flag = flag -- 复用取消旗标（无 timer 时仅作 cancelled）
        task.waiting = true
        local kind_snapshot = req.kind
        handler(req, function(next_input)
          S.when_flow_active(opts, function()
            if flag.cancelled then
              return
            end
            if task.finished or not task.waiting then
              return
            end
            task.waiting = false
            task._timer_flag = nil
            S.emit_trace(opts, {
              type = "resume",
              task_id = task.id,
              kind = kind_snapshot,
            })
            task.answer = Coro.resume(task.answer, next_input)
            if type(opts._pump) == "function" then
              opts._pump()
            end
          end)
        end)
        return "wait"
      else
        local next_input = handler(req)
        S.emit_trace(opts, {
          type = "resume",
          task_id = task.id,
          kind = req.kind,
        })
        task.answer = Coro.resume(task.answer, next_input)
      end
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
