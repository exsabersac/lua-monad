-- wait_vc — fx.wait + Cont.unit，需 VirtualClock / scheduler 推进
local Cont = require("cont")
local fx = require("fx")

local M = {
  id = "wait_vc",
  name = "wait VirtualClock",
  needs_scheduler = true,
  default_wait = 0.01,
}

--- @param opts? { wait?: number, value?: any }
--- @return Cont
function M.build(opts)
  opts = opts or {}
  local wait_s = opts.wait
  if wait_s == nil then
    wait_s = M.default_wait
  end
  local value = opts.value
  if value == nil then
    value = "after-wait"
  end
  return fx.seq({
    fx.wait(wait_s),
    Cont.unit(value),
  })
end

return M
