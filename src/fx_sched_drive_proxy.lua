-- fx_sched_drive_proxy.lua — proxy_join / proxy_stop / proxy_abort 分派
local Coro = require("coro")

local Mod = {}

function Mod.install(S)
  local H = S.drive_handlers

  function H.proxy_join(nursery, task, req)
    local opts = nursery.opts
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
        local extra = stop_host and { proxy_stop_host = true } or nil
        return S.join_finished_or_park(nursery, task, child, want_cancel, extra)
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
      local extra = stop_host and { proxy_stop_host = true } or nil
      return S.join_finished_or_park(nursery, task, child, want_cancel, extra)
    end
  end

  local function proxy_stop_or_abort(nursery, task, req)
    local opts = nursery.opts
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
  end

  H.proxy_stop = proxy_stop_or_abort
  H.proxy_abort = proxy_stop_or_abort
end

return Mod
