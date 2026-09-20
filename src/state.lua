-- state.lua — State 单子（带隐式状态的计算）
--
-- 对应 Haskell Control.Monad.State：
--   State s a  ≈  s → (a, s)
-- 在本库里表示成 function(s) return a, s end；
-- makeMonad 会包成可调用代理 { _fn = f }，故仍可 ma(s0) 或用 runState。
--
-- 辅助：get / put / modify；运行：runState / evalState / execState。

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

-- 读当前状态（结果与状态同为 s）
function M.get()
  return M.wrap(function(s)
    return s, s
  end)
end

-- 覆盖状态；结果值为 nil
function M.put(s_new)
  return M.wrap(function(_s)
    return nil, s_new
  end)
end

-- 用纯函数改造状态；结果值为 nil
function M.modify(f)
  return M.wrap(function(s)
    return nil, f(s)
  end)
end

-- 以初态 s0 跑完整计算，返回 a, s
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
