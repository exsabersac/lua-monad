-- fx_sched.lua — 并行调度器（时间轮）：驱动多个 Cont Answer 任务
--
-- 由 fx.run_parallel / fx.run 内的 when_all·when_any handler 调用。
-- Cont Coro 编码：每个任务 Coro.start；wait 登记 deadline，不串行 busy-wait；
-- connect/click 等瞬时效果立即经 handlers 兑现；when_all/when_any 可嵌套。
--
-- 模式：
--   "all" — 等全部 Done；任一 Failed → 整体 Failed；任一 Stopped → 整体 Stopped
--   "any" — 第一个 Done 胜出，其余视为 cancelled（不再 resume）

local Coro = require("coro")

local M = {}

-- 墙钟时间：并行 wait 的 deadline / sleep 必须一致。
-- os.clock 是 CPU 时间，sleep 期间几乎不推进，会导致「强制唤醒」后二次 sleep（看起来像串行）。
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

-- 推进单个任务的 Answer，直到 Yielded(wait) / 终态 / 嵌套并行需求
-- 返回： "wait" | "done" | "stopped" | "failed" | "nested"
local function drive_until_block(task, handlers, opts, drive_nested)
  while Coro.isYielded(task.answer) do
    if is_cancelled(opts.cancel) then
      task.answer = Coro.Stopped("cancelled")
      return "stopped"
    end
    local req = task.answer.value
    assert(type(req) == "table" and req.kind ~= nil,
      "fx_sched: expected yield payload table with .kind")

    if req.kind == "wait" then
      local secs = req.seconds or 0
      task.deadline = now() + secs
      task.waiting = true
      if opts.verbose_wait then
        print(string.format("[fx.parallel] task#%d wait %.3fs (deadline)", task.index, secs))
      end
      return "wait"
    end

    if req.kind == "when_all" or req.kind == "when_any" then
      local mode = (req.kind == "when_any") and "any" or "all"
      local sub = drive_nested(req.tasks, handlers, opts, mode)
      if not sub.ok then
        if sub.failed then
          task.answer = Coro.Failed(sub.error)
          return "failed"
        end
        task.answer = Coro.Stopped(sub.reason or "cancelled")
        return "stopped"
      end
      local payload
      if mode == "all" then
        payload = sub.values
      else
        payload = { value = sub.value, index = sub.index }
      end
      task.answer = Coro.resume(task.answer, payload)
      -- 继续循环（可能立刻又 yield）
    else
      local handler = handlers[req.kind]
      assert(handler, "fx_sched: no handler for kind=" .. tostring(req.kind))
      local next_input = handler(req)
      task.answer = Coro.resume(task.answer, next_input)
    end
  end

  if Coro.isDone(task.answer) then
    task.waiting = false
    task.deadline = nil
    return "done"
  elseif Coro.isStopped(task.answer) then
    task.waiting = false
    task.deadline = nil
    return "stopped"
  elseif Coro.isFailed(task.answer) then
    task.waiting = false
    task.deadline = nil
    return "failed"
  end
  error("fx_sched: unexpected answer tag=" .. tostring(task.answer and task.answer.tag), 2)
end

-- run_parallel_core : tasks → handlers → opts → mode → result
-- result:
--   all: { ok=true, values={...} } | failed/stopped (+ optional index)
--   any: { ok=true, value=v, index=i } | failed/stopped
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

  local function drive_nested(child_tasks, h, o, m)
    return M.run_parallel(child_tasks, h, o, m)
  end

  local slots = {}
  for i = 1, n do
    local ma = tasks[i]
    assert(ma ~= nil, "fx_sched: tasks[" .. i .. "] is nil")
    slots[i] = {
      index = i,
      answer = Coro.start(ma),
      waiting = false,
      deadline = nil,
      finished = false,
      result = nil, -- Done value
    }
  end

  local finished_count = 0
  local values = {} -- 1..n for when_all
  local winner_index, winner_value

  local function mark_terminal(task, status)
    if task.finished then
      return status
    end
    task.finished = true
    task.waiting = false
    task.deadline = nil
    finished_count = finished_count + 1
    if status == "done" then
      task.result = task.answer.value
      values[task.index] = task.result
      if mode == "any" and winner_index == nil then
        winner_index = task.index
        winner_value = task.result
      end
    end
    return status
  end

  -- 初始推进：处理所有非 wait 的即时效果，直到各任务挂起 wait 或终态
  for i = 1, n do
    local task = slots[i]
    if not task.finished then
      local st = drive_until_block(task, handlers, opts, drive_nested)
      if st == "done" or st == "stopped" or st == "failed" then
        mark_terminal(task, st)
        if mode == "all" and st == "failed" then
          return { ok = false, failed = true, error = task.answer.error, index = i }
        end
        if mode == "all" and st == "stopped" then
          return { ok = false, stopped = true, reason = task.answer.reason, index = i }
        end
        if mode == "any" and st == "done" then
          -- 取消其余
          for j = 1, n do
            if j ~= i and not slots[j].finished then
              slots[j].finished = true
              slots[j].waiting = false
              slots[j].answer = Coro.Stopped("cancelled")
              finished_count = finished_count + 1
            end
          end
          return { ok = true, value = winner_value, index = winner_index }
        end
      end
    end
  end

  while finished_count < n do
    if is_cancelled(opts.cancel) then
      return { ok = false, stopped = true, reason = "cancelled" }
    end

    -- 找最早 deadline
    local min_dl = nil
    local due = {}
    local any_waiting = false
    for i = 1, n do
      local task = slots[i]
      if not task.finished and task.waiting and task.deadline then
        any_waiting = true
        if min_dl == nil or task.deadline < min_dl then
          min_dl = task.deadline
        end
      end
    end

    if not any_waiting then
      -- 没有人在 wait，却还有未完成 → 再推一轮（理论上不应发生）
      local progressed = false
      for i = 1, n do
        local task = slots[i]
        if not task.finished then
          local st = drive_until_block(task, handlers, opts, drive_nested)
          progressed = true
          if st == "done" or st == "stopped" or st == "failed" then
            mark_terminal(task, st)
            if mode == "all" and st == "failed" then
              return { ok = false, failed = true, error = task.answer.error, index = i }
            end
            if mode == "all" and st == "stopped" then
              return { ok = false, stopped = true, reason = task.answer.reason, index = i }
            end
            if mode == "any" and st == "done" then
              for j = 1, n do
                if j ~= i and not slots[j].finished then
                  slots[j].finished = true
                  slots[j].waiting = false
                  slots[j].answer = Coro.Stopped("cancelled")
                  finished_count = finished_count + 1
                end
              end
              return { ok = true, value = winner_value, index = winner_index }
            end
          end
        end
      end
      if not progressed then
        error("fx_sched: deadlock — unfinished tasks not waiting")
      end
    else
      local sleep_for = min_dl - now()
      if sleep_for > 0 then
        busy_wait(sleep_for)
      end
      local tnow = now()
      -- 唤醒所有到期的 wait（允许时钟抖动）
      for i = 1, n do
        local task = slots[i]
        if not task.finished and task.waiting and task.deadline and task.deadline <= tnow + 1e-9 then
          due[#due + 1] = task
        end
      end
      -- 若因浮点未命中任何 due，强制唤醒最早的一个
      if #due == 0 then
        local best
        for i = 1, n do
          local task = slots[i]
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
          print(string.format("[fx.parallel] task#%d wait done", task.index))
        end
        task.answer = Coro.resume(task.answer, true)
        local st = drive_until_block(task, handlers, opts, drive_nested)
        if st == "done" or st == "stopped" or st == "failed" then
          mark_terminal(task, st)
          if mode == "all" and st == "failed" then
            return { ok = false, failed = true, error = task.answer.error, index = task.index }
          end
          if mode == "all" and st == "stopped" then
            return { ok = false, stopped = true, reason = task.answer.reason, index = task.index }
          end
          if mode == "any" and st == "done" then
            for j = 1, n do
              if j ~= task.index and not slots[j].finished then
                slots[j].finished = true
                slots[j].waiting = false
                slots[j].answer = Coro.Stopped("cancelled")
                finished_count = finished_count + 1
              end
            end
            return { ok = true, value = winner_value, index = winner_index }
          end
        end
      end
    end

    -- when_any：若全部终态且无一 Done
    if mode == "any" and finished_count >= n and winner_index == nil then
      -- 找第一个 failed / stopped
      for i = 1, n do
        local a = slots[i].answer
        if Coro.isFailed(a) then
          return { ok = false, failed = true, error = a.error, index = i }
        end
      end
      for i = 1, n do
        local a = slots[i].answer
        if Coro.isStopped(a) then
          return { ok = false, stopped = true, reason = a.reason, index = i }
        end
      end
      return { ok = false, failed = true, error = "when_any: no winner" }
    end
  end

  -- when_all 全部完成
  if mode == "all" then
    -- 再确认无失败（理论上已提前返回）
    for i = 1, n do
      local a = slots[i].answer
      if Coro.isFailed(a) then
        return { ok = false, failed = true, error = a.error, index = i }
      end
      if Coro.isStopped(a) then
        return { ok = false, stopped = true, reason = a.reason, index = i }
      end
    end
    return { ok = true, values = values }
  end

  return { ok = true, value = winner_value, index = winner_index }
end

return M
