-- status.lua — Status / Result 单子（成功或带错误信息的失败）
--
-- 类似 Maybe，但失败分支携带 error 载荷（对照 Haskell Either e a / Result）：
--   Ok v   ≈  { tag = "ok",  value = v }
--   Err e  ≈  { tag = "err", error = e }
--
-- bind 遇 Err 原样短路（保留错误）；Ok 则把 value 交给 f。
--
-- Status ≈ Either：语义已覆盖 Either/Result，故不另建 either.lua，以免重复。

local monad = require("monad")

local function Ok(v)
  return { tag = "ok", value = v }
end

local function Err(e)
  return { tag = "err", error = e }
end

local function isOk(r)
  return type(r) == "table" and r.tag == "ok"
end

local function isErr(r)
  return type(r) == "table" and r.tag == "err"
end

local M = monad.makeMonad({
  unit = Ok,
  bind = function(ma, f)
    if isErr(ma) then
      return ma
    end
    return f(ma.value)
  end,
})

M.Ok = M.unit
M.Err = function(e)
  return M.wrap(Err(e))
end
M.isOk = isOk
M.isErr = isErr

return M
