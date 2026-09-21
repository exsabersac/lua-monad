-- fx_sched_drive_wait.lua — wait / wait_real / wait_event / wait_until 分派
local Coro = require("coro")
local Registry = require("fx_registry")

local Mod = {}

function Mod.install(S)
  local H = S.drive_handlers

  function H.wait(nursery, task, req)
    local handlers = nursery.handlers
    local opts = nursery.opts
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
  end

  function H.wait_real(nursery, task, req)
    local opts = nursery.opts
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
  end

  function H.wait_event(nursery, task, req)
    local handlers = nursery.handlers
    local opts = nursery.opts
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
  end

  function H.wait_until(nursery, task, req)
    local opts = nursery.opts
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
  end
end

return Mod
