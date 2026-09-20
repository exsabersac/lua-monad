-- State monad: function(s) return a, s end
-- Operable values are callable proxies { _fn = f }.

local monad = require("monad")

local function unit(a)
  return function(s)
    return a, s
  end
end

local function bind(ma, f)
  return function(s)
    local a, s2 = ma(s)
    return f(a)(s2)
  end
end

local M = monad.makeMonad({
  unit = unit,
  bind = bind,
})

function M.get()
  return M.wrap(function(s)
    return s, s
  end)
end

function M.put(s_new)
  return M.wrap(function(_s)
    return nil, s_new
  end)
end

function M.modify(f)
  return M.wrap(function(s)
    return nil, f(s)
  end)
end

function M.runState(ma, s0)
  return M.unwrap(ma)(s0)
end

function M.evalState(ma, s0)
  local a, _ = M.runState(ma, s0)
  return a
end

function M.execState(ma, s0)
  local _, s = M.runState(ma, s0)
  return s
end

return M
