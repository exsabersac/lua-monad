-- cont.lua — Cont 续延单子
--
-- Cont r a ≈ (a → r) → r
-- 即「接受最终续延 k，算出类型为 r 的答案」。
-- 本库用 function(k) ... end 表示；wrap 成可调用代理后仍可 ma(k)。
--
--   unit(a)     = λk. k(a)
--   bind(ma, f) = λk. ma(λa. f(a)(k))
--
-- callCC 捕获当前续延，用于提前跳出；runCont 以用户续延执行。
-- coro.lua 建立在 Cont 之上，用答案类型 Done|Yielded 模拟挂起。

local monad = require("monad")

local function unit(a)
  return function(k)
    return k(a)
  end
end

local function bind(ma, f)
  return function(k)
    return ma(function(a)
      return f(a)(k)
    end)
  end
end

local M = monad.makeMonad({
  unit = unit,
  bind = bind,
})

-- callCC : ((a → Cont r b) → Cont r a) → Cont r a
-- escape(a) 忽略后续续延，直接把 a 交给「callCC 当时」的外层 k
function M.callCC(f)
  return M.wrap(function(k)
    local function escape(a)
      return M.wrap(function(_k2)
        return k(a)
      end)
    end
    return M.unwrap(f(escape))(k)
  end)
end

-- runCont : Cont r a → (a → r) → r
function M.runCont(ma, k)
  return M.unwrap(ma)(k)
end

return M
