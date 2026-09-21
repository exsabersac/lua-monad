-- fx_sched_util.lua — 追踪 / 墙钟 / Answer 辅助 / when_flow_active
-- 由 fx_sched 经 install(S, M) 挂到共享袋。

local Coro = require("coro")

local U = {}

function U.install(S, M)
  local _global_tracer = nil
  local _virt = 0

  function S.set_tracer(fn)
    if fn ~= nil and type(fn) ~= "function" then
      error("fx_sched.set_tracer: expected function or nil", 2)
    end
    _global_tracer = fn
  end

  function S.get_tracer()
    return _global_tracer
  end

  function S.emit_trace(opts, ev)
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
      io.stderr:write("[fx.trace] tracer error: " .. tostring(err) .. "\n")
    end
  end

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

  function S.now()
    return wall_now()
  end

  function S.busy_wait(seconds)
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

  function S.is_cancelled(cancel)
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

  function S.answer_status(answer)
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

  function S.propagate_child_failure(child_answer)
    if Coro.isFailed(child_answer) then
      return Coro.Failed(child_answer.error)
    elseif Coro.isAborted(child_answer) then
      return Coro.Aborted(child_answer.reason)
    elseif Coro.isStopped(child_answer) then
      return Coro.Stopped(child_answer.reason)
    end
    error("fx_sched: propagate_child_failure: not a failure answer")
  end

  function S.when_flow_active(opts, fn)
    opts = opts or {}
    local flow = opts._flow
    if flow and flow.suspended then
      flow._deferred = flow._deferred or {}
      flow._deferred[#flow._deferred + 1] = fn
      return
    end
    fn()
  end

  function S.clock_now(opts)
    opts = opts or {}
    local scheduler = opts.scheduler
    if scheduler and type(scheduler.now) == "function" then
      return scheduler.now()
    end
    return S.now()
  end

  M.set_tracer = S.set_tracer
  M.get_tracer = S.get_tracer
  M._emit_trace = S.emit_trace
  M.busy_wait = S.busy_wait
  M.now = S.now
end

return U
