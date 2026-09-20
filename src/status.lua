-- Status / Result monad: { tag = "ok"|"err", value?|error? }

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

M.Ok = Ok
M.Err = Err
M.isOk = isOk
M.isErr = isErr

return M
