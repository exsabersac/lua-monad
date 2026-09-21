-- chan_ping — fork(send) → recv → join，channel 往返
local Cont = require("cont")
local fx = require("fx")

local M = {
  id = "chan_ping",
  name = "chan",
  needs_scheduler = false, -- 同步可 settle；session 下亦可用 VirtualClock
  default_msg = "ping",
}

--- @param opts? { msg?: any, chan?: userdata/table }
--- @return Cont
function M.build(opts)
  opts = opts or {}
  local msg = opts.msg
  if msg == nil then
    msg = M.default_msg
  end
  local ch = opts.chan or fx.chan()
  return fx.fork(fx.send(ch, msg)) >> function(h)
    return fx.recv(ch) >> function(v)
      return fx.join(h) >> function()
        return Cont.unit(v)
      end
    end
  end
end

return M
