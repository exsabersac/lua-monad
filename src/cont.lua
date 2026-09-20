-- Continuation monad: Cont r a = function(k: a -> r) -> r
-- Represented as a function that takes a continuation k.

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

-- callCC : ((a -> Cont r b) -> Cont r a) -> Cont r a
function M.callCC(f)
  return function(k)
    local function escape(a)
      return function(_k2)
        return k(a)
      end
    end
    return f(escape)(k)
  end
end

-- runCont : Cont r a -> (a -> r) -> r
function M.runCont(ma, k)
  return ma(k)
end

return M
