-- identity.lua — Identity 单子（最简单的「盒子」）
--
-- 对应 Haskell Data.Functor.Identity：
--   Identity a  ≈  { tag = "identity", value = a }
--
-- unit / bind 平凡：只是包装与取出再交给续函数。
-- 教学用途：对照「没有额外效应」时 bind 长什么样；也可当类型对齐的占位。

local monad = require("monad")

local function Identity(v)
  return { tag = "identity", value = v }
end

local function isIdentity(m)
  return type(m) == "table" and m.tag == "identity"
end

local function runIdentity(m)
  assert(isIdentity(m), "runIdentity: expected Identity")
  return m.value
end

local M = monad.makeMonad({
  unit = Identity,
  bind = function(ma, f)
    return f(ma.value)
  end,
})

M.Identity = M.unit
M.isIdentity = isIdentity
M.runIdentity = runIdentity

return M
