-- rws.lua — RWS 单子（Reader + Writer + State 合一）
--
-- 对应 Haskell Control.Monad.RWS（简化版，默认 string writer）：
--   RWS r w s a  ≈  r → s → (a, s, w)
-- 本库表示成 function(env, s) return a, s, w end；
-- makeMonad 包成可调用代理。
--
-- 辅助：ask / asks / localEnv / get / put / modify / tell /
--       runRWS / evalRWS / execRWS。

local monad = require("monad")

local function unit(a)
  return function(_env, s)
    return a, s, ""
  end
end

local function bind(ma, f)
  return function(env, s)
    local a, s2, w1 = ma(env, s)
    local b, s3, w2 = f(a)(env, s2)
    return b, s3, w1 .. w2
  end
end

local M = monad.makeMonad({
  unit = unit,
  bind = bind,
})

function M.ask()
  return M.wrap(function(env, s)
    return env, s, ""
  end)
end

function M.asks(f)
  return M.wrap(function(env, s)
    return f(env), s, ""
  end)
end

function M.localEnv(f, ma)
  return M.wrap(function(env, s)
    return M.unwrap(ma)(f(env), s)
  end)
end

function M.get()
  return M.wrap(function(_env, s)
    return s, s, ""
  end)
end

function M.put(s_new)
  return M.wrap(function(_env, _s)
    return nil, s_new, ""
  end)
end

function M.modify(f)
  return M.wrap(function(_env, s)
    return nil, f(s), ""
  end)
end

function M.tell(w)
  return M.wrap(function(_env, s)
    return nil, s, w
  end)
end

-- → a, s, w
function M.runRWS(ma, env, s0)
  return M.unwrap(ma)(env, s0)
end

function M.evalRWS(ma, env, s0)
  local a, _, _ = M.runRWS(ma, env, s0)
  return a
end

function M.execRWS(ma, env, s0)
  local _, s, w = M.runRWS(ma, env, s0)
  return s, w
end

return M
