-- Maybe monad: { tag = "just"|"nothing", value? }

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

-- Constructors return operable (metatable-wrapped) values
M.Just = M.unit
M.Nothing = function()
  return M.wrap(Nothing())
end
M.isJust = isJust
M.isNothing = isNothing
M.fromJust = fromJust

return M
