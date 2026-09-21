-- supervise_once — 第一次 fail，第二次 ok（max_restarts=2）
local Cont = require("cont")
local fx = require("fx")

local M = {
  id = "supervise_once",
  name = "supervise once",
  needs_scheduler = false,
}

--- @param opts? { max_restarts?: number, fail_msg?: string, ok_value?: any }
--- @return Cont
function M.build(opts)
  opts = opts or {}
  local max_restarts = opts.max_restarts
  if max_restarts == nil then
    max_restarts = 2
  end
  local fail_msg = opts.fail_msg or "once"
  local ok_value = opts.ok_value
  if ok_value == nil then
    ok_value = "ok"
  end
  local tries = 0
  return fx.supervise(
    Cont.unit(nil) >> function()
      tries = tries + 1
      if tries == 1 then
        return fx.fail(fail_msg)
      end
      return Cont.unit(ok_value)
    end,
    { max_restarts = max_restarts }
  )
end

return M
