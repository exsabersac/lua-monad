-- lane_pair — 命名 lane 启动 + lane_join
local Cont = require("cont")
local fx = require("fx")

local M = {
  id = "lane_pair",
  name = "lane",
  needs_scheduler = false,
  default_lane = "p",
  default_value = 7,
}

--- @param opts? { lane?: string, value?: any }
--- @return Cont
function M.build(opts)
  opts = opts or {}
  local lane = opts.lane or M.default_lane
  local value = opts.value
  if value == nil then
    value = M.default_value
  end
  return fx.lane(lane, Cont.unit(value)) >> function(_)
    return fx.lane_join(lane)
  end
end

return M
