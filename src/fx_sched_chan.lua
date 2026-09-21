-- fx_sched_chan.lua — 有界 channel（detach / settle / close / admit）
local Coro = require("coro")

local Mod = {}

function Mod.install(S)

function S.detach_chan_waiter(task, mark_cancelled)
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

function S.chan_closed_err(op)
  return {
    tag = "chan_closed",
    op = op,
    message = "channel closed",
  }
end

function S.settle_chan_waiter(waiter, mode, payload)
  if waiter == nil or (waiter.flag and waiter.flag.cancelled) then
    return
  end
  local task = waiter.task
  if task == nil then
    return
  end
  local peer_opts = (task.nursery and task.nursery.opts) or {}
  S.when_flow_active(peer_opts, function()
    if waiter.flag and waiter.flag.cancelled then
      return
    end
    if task.finished then
      return
    end
    if mode ~= "fail" and not task.waiting then
      return
    end
    S.detach_chan_waiter(task, false)
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

function S.assert_chan_req(ch, kind)
  assert(type(ch) == "table" and ch._tag == "fx.chan",
    "fx_sched: " .. kind .. " requires fx.chan channel")
  return ch
end

function S.close_channel(ch)
  if ch.closed then
    return
  end
  ch.closed = true
  while #ch.send_q > 0 do
    local w = table.remove(ch.send_q, 1)
    S.settle_chan_waiter(w, "fail", S.chan_closed_err("send"))
  end
  if #ch.buf == 0 then
    while #ch.recv_q > 0 do
      local w = table.remove(ch.recv_q, 1)
      S.settle_chan_waiter(w, "fail", S.chan_closed_err("recv"))
    end
  end
end

function S.admit_senders(ch)
  while #ch.send_q > 0 and #ch.buf < ch.capacity do
    local w = table.remove(ch.send_q, 1)
    if not (w.flag and w.flag.cancelled) then
      ch.buf[#ch.buf + 1] = w.value
      S.settle_chan_waiter(w, "ok", true)
    end
  end
end

end

return Mod
