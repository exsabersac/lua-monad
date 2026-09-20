-- maybe.lua — Maybe 单子（可失败计算）
--
-- 对应 Haskell Data.Maybe / 教学里的 Maybe a：
--   Just v   ≈  { tag = "just", value = v }
--   Nothing  ≈  { tag = "nothing" }
--
-- bind 在 Nothing 上短路（不调用续函数）；Just 则把 value 交给 f。
-- 值表经 makeMonad.wrap 挂上元表，支持 >> / .. / Maybe(x)。

local monad = require("monad")

local function Just(v)
  return { tag = "just", value = v }
end

local function Nothing()
  return { tag = "nothing" }
end

local function isJust(m)
  return type(m) == "table" and m.tag == "just"
end

local function isNothing(m)
  return type(m) == "table" and m.tag == "nothing"
end

local function fromJust(m)
  assert(isJust(m), "fromJust: expected Just")
  return m.value
end

local M = monad.makeMonad({
  unit = Just,
  bind = function(ma, f)
    if isNothing(ma) then
      return Nothing()
    end
    return f(ma.value)
  end,
})

-- 构造器返回已 wrap 的可操作值（Just 走 unit；Nothing 需手动 wrap）
M.Just = M.unit
M.Nothing = function()
  return M.wrap(Nothing())
end
M.isJust = isJust
M.isNothing = isNothing
M.fromJust = fromJust

-- 顺序 do（原生 coroutine 实现细节）：见 do_coro.lua / docs/顺序do_coro.md
M.runDo = function(body)
  return require("do_coro").runDo(M, body)
end

return M
