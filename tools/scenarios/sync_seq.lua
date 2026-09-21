-- sync_seq — 纯同步 fx.seq({unit, unit, unit})，无 Yield
-- 供 profile / trace / bench 复用，避免重复拼装
local Cont = require("cont")
local fx = require("fx")

local M = {
  id = "sync_seq",
  name = "sync seq",
  needs_scheduler = false,
}

--- @param opts? table  预留；当前无参数
--- @return Cont
function M.build(opts)
  opts = opts or {}
  local a = opts.a or 1
  local b = opts.b or 2
  local c = opts.c or 3
  return fx.seq({
    Cont.unit(a),
    Cont.unit(b),
    Cont.unit(c),
  })
end

return M
