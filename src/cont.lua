-- Continuation monad: Cont r a = function(k: a -> r) -> r
-- Operable values are callable proxies { _fn = f }.

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
  return M.wrap(function(k)
    local function escape(a)
      return M.wrap(function(_k2)
        return k(a)
      end)
    end
    return M.unwrap(f(escape))(k)
  end)
end

-- runCont : Cont r a -> (a -> r) -> r
function M.runCont(ma, k)
  return M.unwrap(ma)(k)
end

return M
