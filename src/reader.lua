-- reader.lua — Reader 单子（只读环境 / 依赖注入）
--
-- 对应 Haskell Control.Monad.Reader：
--   Reader e a  ≈  e → a
-- 在本库里表示成 function(env) return a end；
-- makeMonad 包成可调用代理 { _fn = f }，故仍可 ma(env) 或用 runReader。
--
-- 辅助：ask / asks / localEnv；运行：runReader。
-- （local 是 Lua 关键字，故 local_ 命名为 localEnv。）

local monad = require("monad")

local function unit(a)
  return function(_env)
    return a
  end
end

local function bind(ma, f)
  return function(env)
    return f(ma(env))(env)
  end
end

local M = monad.makeMonad({
  unit = unit,
  bind = bind,
})

-- 读完整环境
function M.ask()
  return M.wrap(function(env)
    return env
  end)
end

-- 用纯函数投影环境：asks(f) ≡ ask >> λe. unit(f(e))
function M.asks(f)
  return M.wrap(function(env)
    return f(env)
  end)
end

-- 在改造后的环境中跑 ma：localEnv(f, ma) 用 f(env) 代替 env
-- （Haskell local；Lua 中 local 为关键字故改名）
function M.localEnv(f, ma)
  return M.wrap(function(env)
    return M.unwrap(ma)(f(env))
  end)
end

-- 以环境 env 跑完整计算，返回 a
function M.runReader(ma, env)
  return M.unwrap(ma)(env)
end

return M
