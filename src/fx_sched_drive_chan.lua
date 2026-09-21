-- fx_sched_drive_chan.lua — chan_send / chan_recv / chan_close 分派
local Coro = require("coro")

local Mod = {}

function Mod.install(S)
  local H = S.drive_handlers

  function H.chan_send(nursery, task, req)
    local opts = nursery.opts
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
  end

  function H.chan_recv(nursery, task, req)
    local opts = nursery.opts
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
  end

  function H.chan_close(nursery, task, req)
    local opts = nursery.opts
    local ch = S.assert_chan_req(req.chan, "chan_close")
    S.emit_trace(opts, { type = "yield", task_id = task.id, kind = "chan_close" })
    S.close_channel(ch)
    task.answer = Coro.resume(task.answer, true)
    S.emit_trace(opts, { type = "resume", task_id = task.id, kind = "chan_close" })
  end
end

return Mod
