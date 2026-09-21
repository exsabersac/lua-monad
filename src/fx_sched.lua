-- fx_sched.lua — 并行 / nursery 调度器（时间轮）
--
-- 统一驱动：
--   · run_session(root_ma) — fx.run 主路径：动态任务集（nursery），支持
--       wait / wait_until / chan_send·recv·close / connect/click /
--       when_all·when_any / fork·join·join_handles / lane·lane_join·lane_stop·lane_abort /
--       proxy_join·proxy_stop·proxy_abort / with_timeout / supervise
--   · run_parallel(tasks, mode) — 顶层 WhenAll/WhenAny（内部走 session）
--
-- Cont Coro 编码：每个任务 Coro.start；无 Yield 的终态走同步快路径（跳过 session 循环）；
-- wait 在多任务时登记 deadline（墙钟），
-- 单任务时可走 handlers.wait（兼容瞬时 mock）；fork 立刻把 handle 还给父任务。
-- 若 opts.scheduler（或 opts.game）提供，wait 走 schedule/cancel，不再 busy_wait；
-- wait_real：scheduler.schedule_real 或 opts.allow_real_time，否则 Failed(wait_real_unsupported)；
-- wait_until 走 schedule_poll（FrameScheduler / GameSim）；无 poll 时用 schedule 轮询模拟；
-- session 可异步完成（timer/poll 回调 resume + pump）。
-- 截止时间：opts.deadline / opts.timeout，以及 with_timeout，向下传播到 fork 子任务；
-- 父 deadline 触发时递归 Stopped 未完成后代（iquit/finally 经 force_stop → Yielded.abort）。
-- Coro.Aborted（fx.abort）：join / when_all / when_any 向 waiter 传播 Aborted（不算成功值）。
-- supervise：子 Failed（可选 Stopped）按 max_restarts/backoff 重启；cancel 当前子且不重启。
-- flow:suspend() / flow:resume()：挂起本 flow 的 wait 兑现（timer/poll 回调推迟到 resume）。
-- flow:proxy(opts?)：轻量 tabProxy 句柄；proxy_join 复用 joiners；可选 stop_host_when_stop。

local Coro = require("coro")
local Cont = require("cont")
local Registry = require("fx_registry")

local M = {}

------------------------------------------------------------
-- 轻量追踪（默认关闭）
-- opts.trace = function(ev) 优先于全局 tracer
-- ev.type: flow_start | yield | resume | fork | join | cancel | done | failed | stopped | aborted
------------------------------------------------------------

local _global_tracer = nil

function M.set_tracer(fn)
  if fn ~= nil and type(fn) ~= "function" then
    error("fx_sched.set_tracer: expected function or nil", 2)
  end
  _global_tracer = fn
end

function M.get_tracer()
  return _global_tracer
end

local function emit_trace(opts, ev)
  local t = nil
  if opts ~= nil then
    t = opts.trace
  end
  if t == nil then
    t = _global_tracer
  end
  if type(t) ~= "function" then
    return
  end
  local ok, err = pcall(t, ev)
  if not ok then
    -- 追踪失败不影响业务；仅 stderr 提示一次形态
    io.stderr:write("[fx.trace] tracer error: " .. tostring(err) .. "\n")
  end
end

M._emit_trace = emit_trace  -- 测试可选用

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
    lanes = {}, -- name → task_id（命名 lane；≈ tabMachine c:start("t1")）
    handlers = handlers or {},
    opts = opts or {},
    root_id = nil,
  }
end

-- pre_answer：已 Coro.start 的 Answer（同步快路径探测后注入，避免二次 start）
local function alloc_task(nursery, ma, pre_answer)
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

-- channel / when_flow_active 前向声明（settle 在定义前引用）
local when_flow_active

-- 从 channel 等待队列摘掉本任务
-- mark_cancelled=true：cancel/终态路径，禁止迟到唤醒
local function detach_chan_waiter(task, mark_cancelled)
  local w = task._chan_waiter
  if w == nil then
    return
  end
  if mark_cancelled and w.flag then
    w.flag.cancelled = true
  end
  local ch = task._chan
  if type(ch) == "table" then
    local function purge(q)
      if type(q) ~= "table" then
        return
      end
      for i = #q, 1, -1 do
        if q[i] == w or (q[i] and q[i].task == task) then
          table.remove(q, i)
        end
      end
    end
    purge(ch.send_q)
    purge(ch.recv_q)
  end
  task._chan_waiter = nil
  task._chan = nil
end

local function chan_closed_err(op)
  return {
    tag = "chan_closed",
    op = op,
    message = "channel closed",
  }
end

-- 唤醒 / 失败 channel 等待方；同 nursery 时 _pump 可能重入（外层继续扫）
local function settle_chan_waiter(waiter, mode, payload)
  if waiter == nil or (waiter.flag and waiter.flag.cancelled) then
    return
  end
  local task = waiter.task
  if task == nil then
    return
  end
  local peer_opts = (task.nursery and task.nursery.opts) or {}
  when_flow_active(peer_opts, function()
    if waiter.flag and waiter.flag.cancelled then
      return
    end
    if task.finished then
      return
    end
    if mode ~= "fail" and not task.waiting then
      return
    end
    detach_chan_waiter(task, false)
    task.waiting = false
    if mode == "fail" then
      task.answer = Coro.Failed(payload)
    else
      task.answer = Coro.resume(task.answer, payload)
    end
    if type(peer_opts._pump) == "function" then
      peer_opts._pump()
    end
  end)
end

local function assert_chan_req(ch, kind)
  assert(type(ch) == "table" and ch._tag == "fx.chan",
    "fx_sched: " .. kind .. " requires fx.chan channel")
  return ch
end

-- 关闭 channel：失败所有 send 等待；缓冲空则失败 recv 等待
local function close_channel(ch)
  if ch.closed then
    return
  end
  ch.closed = true
  while #ch.send_q > 0 do
    local w = table.remove(ch.send_q, 1)
    settle_chan_waiter(w, "fail", chan_closed_err("send"))
  end
  if #ch.buf == 0 then
    while #ch.recv_q > 0 do
      local w = table.remove(ch.recv_q, 1)
      settle_chan_waiter(w, "fail", chan_closed_err("recv"))
    end
  end
end

-- 缓冲腾出空间后，尽量把 send 等待方灌进 buf
local function admit_senders(ch)
  while #ch.send_q > 0 and #ch.buf < ch.capacity do
    local w = table.remove(ch.send_q, 1)
    if not (w.flag and w.flag.cancelled) then
      ch.buf[#ch.buf + 1] = w.value
      settle_chan_waiter(w, "ok", true)
    end
  end
end

-- 前向：supervise backoff 清理（定义在 clear_task_waits / force_stop 之后）
local clear_supervise_backoff

-- 清除 wait / wait_event / chan 占用的 timer / listener / 队列；迟到回调靠 cancelled 旗标忽略
-- 前向：proxy stop_host_when_stop（定义在 stop_task 之后）
local apply_proxy_stop_host

local function clear_task_waits(task)
  -- 等待方被取消：可选反向停 proxy 目标（须在清 wait 前，保留 join_target）
  if apply_proxy_stop_host and task.proxy_stop_host then
    apply_proxy_stop_host(task)
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
  detach_chan_waiter(task, true)
  -- supervise 等待 backoff 时，父 parked；cancel 须拆掉 scheduler handle
  if task.waiting_group and task.waiting_group.mode == "supervise" then
    clear_supervise_backoff(task.waiting_group, opts, task.nursery)
  end
  task.deadline = nil
  task.waiting = false
  task.waiting_event = false
  task._wait_until_pred = nil
  task._wait_until_interval = nil
  task._wait_until_next = nil
end

local function mark_finished(task)
  clear_task_waits(task)
  task.finished = true
  task.parked = nil
end

-- 经 with_iquit/with_finally.abort 停任务，保证 iquit→finally 执行
local function force_stop_task_answer(answer, reason)
  return Coro.force_stop(answer, reason or "cancelled")
end

-- supervise backoff 清理：scheduler handle（遗留）+ wait 任务
clear_supervise_backoff = function(group, opts, nursery)
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
      clear_task_waits(t)
      t.answer = force_stop_task_answer(t.answer, "cancelled")
      t._supervise_backoff_group = nil
      mark_finished(t)
      t._terminal_handled = true
    end
  end
end

-- Answer → 调度器用的终态标签
local function answer_status(answer)
  if Coro.isDone(answer) then
    return "done"
  elseif Coro.isAborted(answer) then
    return "aborted"
  elseif Coro.isStopped(answer) then
    return "stopped"
  elseif Coro.isFailed(answer) then
    return "failed"
  end
  return nil
end

-- 向父/joiner 传播子任务的非成功终态（保留 Aborted vs Stopped）
local function propagate_child_failure(child_answer)
  if Coro.isFailed(child_answer) then
    return Coro.Failed(child_answer.error)
  elseif Coro.isAborted(child_answer) then
    return Coro.Aborted(child_answer.reason or "aborted")
  elseif Coro.isStopped(child_answer) then
    return Coro.Stopped(child_answer.reason or "cancelled")
  end
  error("fx_sched: expected Failed/Aborted/Stopped to propagate")
end

-- flow:suspend 时推迟 timer/poll 兑现；resume 时按序执行
when_flow_active = function(opts, fn)
  local flow = opts and opts._flow
  if flow and flow.suspended and not flow.done then
    local q = flow._deferred
    if q == nil then
      q = {}
      flow._deferred = q
    end
    q[#q + 1] = fn
    return
  end
  fn()
end

-- 当前时钟：有 scheduler 用游戏时间，否则墙钟
local function clock_now(opts)
  opts = opts or {}
  local scheduler = opts.scheduler
  if scheduler ~= nil and type(scheduler.now) == "function" then
    return scheduler.now()
  end
  return now()
end

-- 收紧任务绝对截止时间（取更早者）
local function apply_deadline_abs(task, abs)
  if abs == nil or task == nil then
    return
  end
  if task.deadline_abs == nil or abs < task.deadline_abs then
    task.deadline_abs = abs
  end
end

-- 子任务继承父任务剩余 deadline
local function inherit_deadline(child, parent)
  if child == nil or parent == nil then
    return
  end
  if parent.deadline_abs ~= nil then
    apply_deadline_abs(child, parent.deadline_abs)
  end
end

-- 前向声明
local drive_until_block
local on_task_terminal
local settle_group
local try_complete_joins
local cancel_descendants
local try_supervise_after_child
local spawn_supervise_child

-- 取消 ancestor 的所有未完成后代（不含 ancestor 自身）；经 force_stop 跑 finally
cancel_descendants = function(nursery, ancestor_id, reason)
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
      clear_task_waits(t)
      t.answer = force_stop_task_answer(t.answer, reason)
      if not t._terminal_handled then
        on_task_terminal(nursery, t, "stopped")
      else
        mark_finished(t)
      end
    end
  end
end

local function cancel_siblings(nursery, group, except_id)
  for _, cid in ipairs(group.child_ids) do
    if cid ~= except_id then
      local c = nursery.tasks[cid]
      if c and not c.finished then
        -- 先停后代（fork 子树），再停组员本身
        cancel_descendants(nursery, cid, "cancelled")
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
        cancel_descendants(nursery, id, reason)
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


-- 停止/中止单个任务（先停后代再停自身）；mode="stop"|"abort"
-- 返回 true=曾在跑并已终态化；false=nil/已结束
local function stop_task(nursery, child, mode, reason)
  if child == nil or child.finished then
    return false
  end
  if mode == "abort" then
    reason = reason or "abort"
  else
    reason = reason or "stop"
  end
  cancel_descendants(nursery, child.id, reason)
  clear_task_waits(child)
  if mode == "abort" then
    if Coro.isYielded(child.answer) and type(child.answer.abort) == "function" then
      child.answer.abort(reason)
    end
    child.answer = Coro.Aborted(reason)
    if not child._terminal_handled then
      on_task_terminal(nursery, child, "aborted")
    else
      mark_finished(child)
    end
  else
    child.answer = force_stop_task_answer(child.answer, reason)
    if not child._terminal_handled then
      on_task_terminal(nursery, child, "stopped")
    else
      mark_finished(child)
    end
  end
  return true
end

-- 按名停止/中止 lane；mode="stop"|"abort"
local function stop_named_lane(nursery, name, mode, reason)
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
  return stop_task(nursery, child, mode, reason)
end

-- proxy 目标解析：返回 child|nil, kind ("task"|"lane"|"flow"|"unknown")
local function resolve_proxy_target(nursery, proxy)
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

-- 从 host.joiners 摘掉 joiner（避免反向 stop 时再唤醒正在取消的等待方）
local function detach_joiner(host, joiner_id)
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

-- stop_host_when_stop：等待方被取消时反向停目标
apply_proxy_stop_host = function(task)
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
    detach_joiner(nursery.tasks[host_id], task.id)
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
      stop_task(nursery, host, "stop", reason)
    end
  end
end

-- flow 终态 → 唤醒跨 session 的 proxy_join 等待方
local function map_flow_result_to_joiner(nursery, j, result)
  if result.ok then
    j.answer = Coro.resume(j.answer, result.value)
  elseif result.aborted then
    j.answer = Coro.Aborted(result.reason)
    mark_finished(j)
    on_task_terminal(nursery, j, "aborted")
  elseif result.stopped then
    j.answer = Coro.Stopped(result.reason)
    mark_finished(j)
    on_task_terminal(nursery, j, "stopped")
  elseif result.failed then
    j.answer = Coro.Failed(result.error)
    mark_finished(j)
    on_task_terminal(nursery, j, "failed")
  else
    error("fx_sched: flow proxy_join unexpected result shape")
  end
end

local function notify_flow_proxy_joiners(flow)
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
      map_flow_result_to_joiner(nursery, j, result)
      local pump = nursery.opts and nursery.opts._pump
      if type(pump) == "function" then
        pump()
      end
    end
  end
end

local function attach_flow_proxy_method(flow)
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
  elseif status == "done" and group.mode == "supervise" then
    clear_supervise_backoff(group, nursery.opts, nursery)
    parent.waiting_group = nil
    parent.answer = Coro.resume(parent.answer, child.result)
  elseif status == "failed" then
    if group.mode == "supervise" then
      clear_supervise_backoff(group, nursery.opts, nursery)
      parent.waiting_group = nil
    end
    parent.answer = Coro.Failed(child.answer.error)
    parent.fail_index = child.group_pos
    cancel_siblings(nursery, group, child.id)
    on_task_terminal(nursery, parent, "failed")
  elseif status == "stopped" then
    if group.mode == "supervise" then
      clear_supervise_backoff(group, nursery.opts, nursery)
      parent.waiting_group = nil
    end
    parent.answer = Coro.Stopped(child.answer.reason or "cancelled")
    parent.fail_index = child.group_pos
    cancel_siblings(nursery, group, child.id)
    on_task_terminal(nursery, parent, "stopped")
  elseif status == "aborted" then
    if group.mode == "supervise" then
      clear_supervise_backoff(group, nursery.opts, nursery)
      parent.waiting_group = nil
    end
    parent.answer = Coro.Aborted(child.answer.reason or "aborted")
    parent.fail_index = child.group_pos
    cancel_siblings(nursery, group, child.id)
    on_task_terminal(nursery, parent, "aborted")
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

  -- supervise backoff 等待任务（非 group 子）：到期后启下一轮
  if task._supervise_backoff_group then
    local g = task._supervise_backoff_group
    task._supervise_backoff_group = nil
    if g._backoff_task_id == task.id then
      g._backoff_task_id = nil
    end
    if status == "done" and not g.settled then
      spawn_supervise_child(nursery, g)
    end
    -- Stopped/Failed of backoff：cancel 路径，不再重启
    try_complete_joins(nursery, task, status)
    return
  end

  -- 结构化 when_all / when_any / timeout / supervise
  local group = task.group_ref
  if group and not group.settled then
    if group.mode == "supervise" then
      try_supervise_after_child(nursery, group, task, status)
    elseif status == "done" then
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
              if c and Coro.isAborted(c.answer) then
                settle_group(nursery, group, "aborted", c)
                break
              end
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
    elseif status == "stopped" or status == "aborted" then
      if group.mode == "all" or group.mode == "timeout" then
        -- timeout：body Stopped/Aborted 立刻传播（并取消 timer）
        settle_group(nursery, group, status, task)
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
              if c and Coro.isAborted(c.answer) then
                settle_group(nursery, group, "aborted", c)
                break
              end
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
        j.proxy_stop_host = nil
        j.proxy_host_flow = nil
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
        elseif status == "aborted" then
          j.answer = Coro.Aborted(finished_task.answer.reason)
          mark_finished(j)
          on_task_terminal(nursery, j, "aborted")
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
          elseif status == "aborted" then
            j.parked = nil
            j.answer = Coro.Aborted(finished_task.answer.reason)
            mark_finished(j)
            on_task_terminal(nursery, j, "aborted")
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
    inherit_deadline(child, parent)
    group.child_ids[i] = child.id
  end
  parent.parked = "group"
  parent.waiting_group = group -- 正在等待的组（≠ 作为子任务的 group_ref）
  return "parked"
end


-- 启动 with_timeout：body 与 wait(seconds) 竞速
-- 若父任务已有 deadline_abs，取更紧的剩余时间；body 打上绝对截止供 fork 继承
local function start_timeout_race(nursery, parent, req)
  local ma = req.task
  local secs = req.seconds or 0
  local on_timeout = req.on_timeout or "timeout"
  assert(ma ~= nil, "fx_sched: with_timeout requires .task")

  local opts = nursery.opts or {}
  local tnow = clock_now(opts)
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

  local body = alloc_task(nursery, ma)
  body.group_ref = group
  body.group_pos = 1
  body.timeout_role = "body"
  body.parent_id = parent.id
  apply_deadline_abs(body, abs)
  group.child_ids[1] = body.id

  local timer_ma = Coro.yield({ kind = "wait", seconds = effective }) >> function(_)
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

-- 启动 supervise：跑 child；Failed（可选 Stopped）时重启
local function start_supervise(nursery, parent, req)
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
  spawn_supervise_child(nursery, group)
  return "parked"
end

spawn_supervise_child = function(nursery, group)
  if group.settled then
    return
  end
  local parent = nursery.tasks[group.parent_id]
  if not parent or parent.finished then
    return
  end
  local opts = nursery.opts or {}
  if is_cancelled(opts.cancel) then
    settle_group(nursery, group, "stopped", {
      id = 0,
      group_pos = 0,
      answer = Coro.Stopped("cancelled"),
    })
    return
  end
  local child = alloc_task(nursery, group.ma)
  child.group_ref = group
  child.group_pos = #group.child_ids + 1
  child.parent_id = parent.id
  inherit_deadline(child, parent)
  group.child_ids[#group.child_ids + 1] = child.id
  group.current_child_id = child.id
  group.n = #group.child_ids
  emit_trace(opts, {
    type = "supervise_start",
    task_id = parent.id,
    child_id = child.id,
    attempt = group.restarts + 1,
    restarts = group.restarts,
  })
end

local function supervise_should_restart(group, child, status)
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

local function schedule_supervise_restart(nursery, group)
  local parent = nursery.tasks[group.parent_id]
  if not parent or parent.finished or group.settled then
    return
  end
  local opts = nursery.opts or {}
  local backoff = group.backoff or 0

  if backoff <= 0 then
    if is_cancelled(opts.cancel) then
      settle_group(nursery, group, "stopped", {
        id = 0,
        group_pos = 0,
        answer = Coro.Stopped("cancelled"),
      })
      return
    end
    spawn_supervise_child(nursery, group)
    return
  end

  -- backoff：用 wait 任务（有 scheduler 时走游戏时间 schedule；否则时间轮/busy）
  -- 必须是 nursery 任务，否则 pump 会把「仅 parked 的 supervise」当成 deadlock
  local timer_ma = Coro.yield({ kind = "wait", seconds = backoff }) >> function(_)
    return Cont.unit(true)
  end
  local timer = alloc_task(nursery, timer_ma)
  timer.parent_id = parent.id
  timer._supervise_backoff_group = group
  group._backoff_task_id = timer.id
end

try_supervise_after_child = function(nursery, group, child, status)
  local parent = nursery.tasks[group.parent_id]
  if not parent or parent.finished then
    return
  end
  if status == "done" then
    settle_group(nursery, group, "done", child)
    return
  end
  if supervise_should_restart(group, child, status) then
    group.restarts = group.restarts + 1
    emit_trace(nursery.opts, {
      type = "supervise_restart",
      task_id = parent.id,
      child_id = child.id,
      restarts = group.restarts,
      max_restarts = group.max_restarts,
      status = status,
      error = child.answer and child.answer.error,
      reason = child.answer and child.answer.reason,
    })
    schedule_supervise_restart(nursery, group)
    return
  end
  settle_group(nursery, group, status, child)
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
      emit_trace(opts, { type = "yield", task_id = task.id, kind = "wait", seconds = secs })
      local scheduler = opts.scheduler
      -- 外部 Scheduler：登记 timer，不 busy_wait；回调里 resume + pump
      if scheduler ~= nil then
        local flag = { cancelled = false }
        local handle = scheduler.schedule(secs, function()
          when_flow_active(opts, function()
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
    -- wait_real：墙钟等待（opt-in；默认 Failed）
    --   scheduler.schedule_real → 宿主 realtime
    --   opts.allow_real_time → busy_wait
    --   否则 → Failed{tag=wait_real_unsupported}
    ------------------------------------------------------------
    elseif req.kind == "wait_real" then
      local secs = req.seconds or 0
      emit_trace(opts, { type = "yield", task_id = task.id, kind = "wait_real", seconds = secs })
      local scheduler = opts.scheduler
      if scheduler ~= nil and type(scheduler.schedule_real) == "function" then
        local flag = { cancelled = false }
        local handle = scheduler.schedule_real(secs, function()
          when_flow_active(opts, function()
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
              print(string.format("[fx.session] task#%d wait_real done (schedule_real)", task.id))
            end
            emit_trace(opts, { type = "resume", task_id = task.id, kind = "wait_real" })
            task.answer = Coro.resume(task.answer, true)
            if type(opts._pump) == "function" then
              opts._pump()
            end
          end)
        end)
        task.timer_handle = handle
        task._timer_flag = flag
        task.waiting = true
        if opts.verbose_wait then
          print(string.format("[fx.session] task#%d wait_real %.3fs (schedule_real)", task.id, secs))
        end
        return "wait"
      elseif opts.allow_real_time then
        if opts.verbose_wait then
          print(string.format("[fx.session] task#%d wait_real %.3fs (allow_real_time busy)", task.id, secs))
        end
        busy_wait(secs)
        emit_trace(opts, { type = "resume", task_id = task.id, kind = "wait_real" })
        task.answer = Coro.resume(task.answer, true)
      else
        local err = {
          tag = "wait_real_unsupported",
          message = "wait_real unsupported",
          effect_kind = "wait_real",
        }
        emit_trace(opts, {
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
      emit_trace(opts, { type = "yield", task_id = task.id, kind = req.kind })
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
    -- supervise：子失败时按策略重启
    ------------------------------------------------------------
    elseif req.kind == "supervise" then
      emit_trace(opts, { type = "yield", task_id = task.id, kind = "supervise" })
      local st = start_supervise(nursery, task, req)
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
      inherit_deadline(child, task) -- 继承父剩余 deadline
      local handle = { id = child.id }
      emit_trace(opts, {
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
      emit_trace(opts, {
        type = "join",
        task_id = task.id,
        target_id = h.id,
      })
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
        elseif Coro.isAborted(child.answer) then
          task.answer = Coro.Aborted(child.answer.reason)
          return "aborted"
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
      local child = alloc_task(nursery, ma)
      child.parent_id = task.id
      child.lane_name = name
      inherit_deadline(child, task)
      nursery.lanes[name] = child.id
      local handle = { id = child.id, name = name }
      emit_trace(opts, {
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
      emit_trace(opts, {
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
            cancel_fork_siblings(nursery, { [child.id] = true }, task.id, "cancelled")
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
      emit_trace(opts, {
        type = "cancel",
        task_id = task.id,
        lane = name,
        mode = mode,
      })
      local ok = stop_named_lane(nursery, name, mode, reason)
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
        emit_trace(opts, {
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
                cancel_fork_siblings(nursery, { [child.id] = true }, task.id, "cancelled")
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
        local child, kind = resolve_proxy_target(nursery, proxy)
        if kind == "unknown" or child == nil then
          task.answer = Coro.Failed({
            tag = "proxy_unknown",
            name = proxy.name,
            id = proxy.id,
          })
          return "failed"
        end
        emit_trace(opts, {
          type = "join",
          task_id = task.id,
          target_id = child.id,
          proxy = kind,
        })
        if child.finished then
          if Coro.isDone(child.answer) then
            task.answer = Coro.resume(task.answer, child.result)
            if want_cancel then
              cancel_fork_siblings(nursery, { [child.id] = true }, task.id, "cancelled")
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
      emit_trace(opts, {
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
              cancel_descendants(n, root.id, reason)
              clear_task_waits(root)
              if Coro.isYielded(root.answer) and type(root.answer.abort) == "function" then
                root.answer.abort(reason)
              end
              root.answer = Coro.Aborted(reason)
              mark_finished(root)
              root._terminal_handled = true
            end
            fl.done = true
            fl.result = { ok = false, aborted = true, reason = reason }
            notify_flow_proxy_joiners(fl)
            ok = true
          elseif type(fl.cancel) == "function" then
            fl.cancel(reason)
            ok = true
          end
        end
      else
        local child, kind = resolve_proxy_target(nursery, proxy)
        if child ~= nil then
          ok = stop_task(nursery, child, mode, reason)
        end
      end
      task.answer = Coro.resume(task.answer, ok)

    ------------------------------------------------------------
    -- wait_event：事件总线 listen；无总线则走 handlers.wait_event
    ------------------------------------------------------------
    elseif req.kind == "wait_event" then
      emit_trace(opts, {
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
          when_flow_active(opts, function()
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
          emit_trace(opts, {
            type = "failed",
            task_id = task.id,
            error = err,
            kind = "wait_event",
          })
          task.answer = Coro.Failed(err)
          return "failed"
        end
        local next_input = handler(req)
        emit_trace(opts, {
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
      emit_trace(opts, {
        type = "yield",
        task_id = task.id,
        kind = "wait_until",
        interval = interval,
      })
      local scheduler = opts.scheduler

      local function resume_until(result)
        when_flow_active(opts, function()
          if task.finished or not task.waiting then
            return
          end
          task.waiting = false
          task.timer_handle = nil
          task._timer_flag = nil
          task._wait_until_pred = nil
          task._wait_until_interval = nil
          task._wait_until_next = nil
          emit_trace(opts, {
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
        when_flow_active(opts, function()
          if task.finished then
            return
          end
          clear_task_waits(task)
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
            if live_count(nursery) > 1 then
              task._wait_until_pred = pred
              task._wait_until_interval = interval
              task._wait_until_next = now() + (interval > 0 and interval or 0)
              task.waiting = true
              return "wait"
            else
              local step = interval
              if step <= 0 then
                step = 0.001
              end
              while true do
                if is_cancelled(opts.cancel) then
                  task.answer = force_stop_task_answer(task.answer, "cancelled")
                  return "stopped"
                end
                busy_wait(step)
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
      local ch = assert_chan_req(req.chan, "chan_send")
      local value = req.value
      emit_trace(opts, { type = "yield", task_id = task.id, kind = "chan_send" })
      if ch.closed then
        task.answer = Coro.Failed(chan_closed_err("send"))
        return "failed"
      end
      local delivered = false
      -- 优先交给等待中的 recv（会合 / 直送）
      while #ch.recv_q > 0 do
        local w = table.remove(ch.recv_q, 1)
        if not (w.flag and w.flag.cancelled) then
          settle_chan_waiter(w, "ok", value)
          task.answer = Coro.resume(task.answer, true)
          emit_trace(opts, { type = "resume", task_id = task.id, kind = "chan_send" })
          delivered = true
          break
        end
      end
      if not delivered then
        if #ch.buf < ch.capacity then
          ch.buf[#ch.buf + 1] = value
          task.answer = Coro.resume(task.answer, true)
          emit_trace(opts, { type = "resume", task_id = task.id, kind = "chan_send" })
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
      local ch = assert_chan_req(req.chan, "chan_recv")
      emit_trace(opts, { type = "yield", task_id = task.id, kind = "chan_recv" })
      if #ch.buf > 0 then
        local value = table.remove(ch.buf, 1)
        admit_senders(ch)
        task.answer = Coro.resume(task.answer, value)
        emit_trace(opts, { type = "resume", task_id = task.id, kind = "chan_recv" })
      else
        -- 缓冲空：尝试会合 send 等待方
        local matched = false
        while #ch.send_q > 0 do
          local w = table.remove(ch.send_q, 1)
          if not (w.flag and w.flag.cancelled) then
            local value = w.value
            settle_chan_waiter(w, "ok", true)
            task.answer = Coro.resume(task.answer, value)
            emit_trace(opts, { type = "resume", task_id = task.id, kind = "chan_recv" })
            matched = true
            break
          end
        end
        if not matched then
          if ch.closed then
            task.answer = Coro.Failed(chan_closed_err("recv"))
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
      local ch = assert_chan_req(req.chan, "chan_close")
      emit_trace(opts, { type = "yield", task_id = task.id, kind = "chan_close" })
      close_channel(ch)
      task.answer = Coro.resume(task.answer, true)
      emit_trace(opts, { type = "resume", task_id = task.id, kind = "chan_close" })

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
        emit_trace(opts, {
          type = "failed",
          task_id = task.id,
          error = err,
          kind = req.kind,
        })
        task.answer = Coro.Failed(err)
        return "failed"
      end
      emit_trace(opts, {
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
          when_flow_active(opts, function()
            if flag.cancelled then
              return
            end
            if task.finished or not task.waiting then
              return
            end
            task.waiting = false
            task._timer_flag = nil
            emit_trace(opts, {
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
        emit_trace(opts, {
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

------------------------------------------------------------
-- start_session / run_session
--   start_session → flow handle（可异步）；timer/事件回调里 pump
--   同步快路径：Coro.start 立刻终态（未 Yield）→ settled flow，无 nursery
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

-- 同步终态 → 最小 settled flow（无 nursery / pump）
local function make_settled_flow(result)
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
  attach_flow_proxy_method(flow)
  return flow
end

local function result_from_terminal_answer(answer)
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

local function emit_settle_traces(opts, root_id, result)
  if result.ok then
    emit_trace(opts, { type = "done", root_id = root_id, value = result.value })
  elseif result.aborted then
    emit_trace(opts, { type = "aborted", root_id = root_id, reason = result.reason })
  elseif result.stopped then
    emit_trace(opts, { type = "stopped", root_id = root_id, reason = result.reason })
  elseif result.failed then
    emit_trace(opts, { type = "failed", root_id = root_id, error = result.error })
  end
end

function M.start_session(ma, handlers, opts)
  opts = normalize_sched_opts(opts)
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
      deadline_abs = clock_now(opts) + opts.timeout
    end
    emit_trace(opts, {
      type = "flow_start",
      root_id = root_id,
      deadline_abs = deadline_abs,
    })
    local result
    -- 与 pump 一致：cancel 优先于已算完的终态（Cont 已在 start 时求值完毕）
    if is_cancelled(opts.cancel) then
      result = { ok = false, stopped = true, reason = "cancelled" }
      emit_trace(opts, { type = "cancel", root_id = root_id, reason = "cancelled" })
      emit_trace(opts, { type = "stopped", root_id = root_id, reason = "cancelled" })
    else
      result = result_from_terminal_answer(answer)
      emit_settle_traces(opts, root_id, result)
    end
    return make_settled_flow(result)
  end

  local nursery = new_nursery(handlers, opts)
  local root = alloc_task(nursery, ma, answer)
  nursery.root_id = root.id

  -- session 级截止：opts.deadline（绝对）或 opts.timeout（相对秒）
  local t0 = clock_now(opts)
  if opts.deadline ~= nil then
    assert(type(opts.deadline) == "number",
      "fx_sched: opts.deadline must be number (absolute clock)")
    apply_deadline_abs(root, opts.deadline)
  elseif opts.timeout ~= nil then
    assert(type(opts.timeout) == "number" and opts.timeout >= 0,
      "fx_sched: opts.timeout must be number >= 0 (seconds)")
    apply_deadline_abs(root, t0 + opts.timeout)
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

  emit_trace(opts, {
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
      emit_trace(opts, { type = "done", root_id = root.id, value = r.value })
    elseif r.aborted then
      emit_trace(opts, { type = "aborted", root_id = root.id, reason = r.reason })
    elseif r.stopped then
      emit_trace(opts, { type = "stopped", root_id = root.id, reason = r.reason })
    elseif r.failed then
      emit_trace(opts, { type = "failed", root_id = root.id, error = r.error })
    end
    notify_flow_proxy_joiners(flow)
    return flow.result
  end

  -- session / 继承截止触发：子树 Stopped（finally），根 Failed(on_timeout)
  local function fire_session_deadline()
    if flow.done then
      return flow.result
    end
    emit_trace(opts, {
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
        clear_task_waits(t)
        t.answer = force_stop_task_answer(t.answer, "cancelled")
        if not t._terminal_handled then
          on_task_terminal(nursery, t, "stopped")
        else
          mark_finished(t)
        end
      end
    end
    if not root.finished then
      clear_task_waits(root)
      root.answer = Coro.Failed(session_on_timeout)
      mark_finished(root)
      root._terminal_handled = true
    end
    flow.done = true
    flow.result = { ok = false, failed = true, error = session_on_timeout }
    emit_trace(opts, {
      type = "failed",
      root_id = root.id,
      error = session_on_timeout,
    })
    notify_flow_proxy_joiners(flow)
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
            if st == "done" or st == "stopped" or st == "aborted" or st == "failed" then
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
      if flow.suspended then
        pumping = false
        return nil
      end
      if is_cancelled(opts.cancel) then
        clear_deadline_watchdog()
        emit_trace(opts, { type = "cancel", root_id = root.id, reason = "cancelled" })
        cancel_all_unfinished(nursery, "cancelled")
        if not root.finished then
          root.answer = force_stop_task_answer(root.answer, "cancelled")
          mark_finished(root)
          root._terminal_handled = true
        end
        flow.done = true
        flow.result = { ok = false, stopped = true, reason = "cancelled" }
        emit_trace(opts, { type = "stopped", root_id = root.id, reason = "cancelled" })
        notify_flow_proxy_joiners(flow)
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
            local nxt = task._wait_until_next or now()
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
        local sleep_for = min_dl - now()
        if sleep_for > 0 then
          busy_wait(sleep_for)
        end
        local tnow = now()
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
          local st = drive_until_block(nursery, task)
          if st == "done" or st == "stopped" or st == "aborted" or st == "failed" then
            on_task_terminal(nursery, task, st)
          end
        end
        -- wait_until（无 scheduler 演示路径）：到点则 poll
        for _, task in pairs(nursery.tasks) do
          if not task.finished and task.waiting and task._wait_until_pred
              and (task._wait_until_next or 0) <= tnow + 1e-9 then
            local ok, result = pcall(task._wait_until_pred)
            if not ok then
              clear_task_waits(task)
              task.answer = Coro.Failed(result)
              on_task_terminal(nursery, task, "failed")
            elseif result then
              task.waiting = false
              task._wait_until_pred = nil
              task._wait_until_interval = nil
              task._wait_until_next = nil
              task.answer = Coro.resume(task.answer, result)
              local st = drive_until_block(nursery, task)
              if st == "done" or st == "stopped" or st == "aborted" or st == "failed" then
                on_task_terminal(nursery, task, st)
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
    clear_deadline_watchdog()
    emit_trace(opts, { type = "cancel", root_id = root.id, reason = reason })
    cancel_all_unfinished(nursery, reason)
    if not root.finished then
      root.answer = force_stop_task_answer(root.answer, reason)
      mark_finished(root)
      root._terminal_handled = true
    end
    flow.done = true
    flow.result = { ok = false, stopped = true, reason = reason }
    emit_trace(opts, { type = "stopped", root_id = root.id, reason = reason })
    notify_flow_proxy_joiners(flow)
    return flow.result
  end

  function flow.is_done()
    return flow.done
  end

  opts._pump = pump
  nursery.opts = opts -- 确保 clear_task_waits 见到 _pump/scheduler
  attach_flow_proxy_method(flow)

  -- 有 scheduler 时挂 deadline 看门狗（游戏时间）
  if root.deadline_abs ~= nil and opts.scheduler ~= nil then
    local delay = root.deadline_abs - clock_now(opts)
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
