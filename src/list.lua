-- list.lua — List 单子（非确定性 / 多结果）
--
-- 对应 Haskell 的 []：用 Lua 数组表示；
--   unit(x)     = { x }
--   bind(xs, f) = concat(map f xs)   —— 对每个元素应用 f 再展平一层
--
-- 空列表 bind 得到空列表（零个结果）。值表经 wrap 后可用 >> / ..。

local monad = require("monad")

local function singleton(x)
  return { x }
end

-- 展平：[[a]] → [a]（一层）
local function concat(xss)
  local out = {}
  for _, xs in ipairs(xss) do
    for _, x in ipairs(xs) do
      out[#out + 1] = x
    end
  end
  return out
end

local M = monad.makeMonad({
  unit = singleton,
  bind = function(xs, f)
    local parts = {}
    for _, x in ipairs(xs) do
      parts[#parts + 1] = f(x)
    end
    return concat(parts)
  end,
})

M.singleton = M.unit
M.concat = function(xss)
  return M.wrap(concat(xss))
end
M.empty = function()
  return M.wrap({})
end

return M
