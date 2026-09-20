-- List monad: Lua arrays; bind flattens.

local monad = require("monad")

local function singleton(x)
  return { x }
end

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
