-- Generic monad constructor with metatable operator sugar.
-- makeMonad({ unit = f, bind = g [, then_ = h] })
--
-- Operable values support (Lua 5.3+/5.4):
--   ma >> f     via __shr     →  m.bind(ma, f)
--   ma .. mb    via __concat  →  m.bind(ma, function(_) return mb end)  -- Haskell >>
--
-- Table-shaped monads (Maybe, List, Status): setmetatable on the value table.
-- Function-shaped monads (Cont, State): callable proxy { _fn = f }.

local function makeMonad(spec)
  assert(type(spec) == "table", "makeMonad: spec must be a table")
  assert(type(spec.unit) == "function", "makeMonad: unit required")
  assert(type(spec.bind) == "function", "makeMonad: bind required")

  local m = {}
  local mt = {}

  local function unwrap(x)
    if type(x) == "table" and getmetatable(x) == mt and x._fn ~= nil then
      return x._fn
    end
    return x
  end

  local function wrap(x)
    if type(x) == "table" and getmetatable(x) == mt then
      return x
    end
    if type(x) == "function" then
      return setmetatable({ _fn = x }, mt)
    end
    if type(x) == "table" then
      return setmetatable(x, mt)
    end
    return x
  end

  mt.__shr = function(ma, f)
    return m.bind(ma, f)
  end

  -- Sequence / discard left (Haskell >>)
  mt.__concat = function(ma, mb)
    return m.bind(ma, function(_)
      return mb
    end)
  end

  mt.__call = function(ma, ...)
    local fn = ma._fn
    assert(type(fn) == "function", "monad value is not callable")
    return fn(...)
  end

  local raw_unit = spec.unit
  local raw_bind = spec.bind

  function m.unit(a)
    return wrap(raw_unit(a))
  end

  function m.bind(ma, f)
    return wrap(raw_bind(unwrap(ma), function(a)
      return unwrap(f(a))
    end))
  end

  m.unwrap = unwrap
  m.wrap = wrap

  if type(spec.then_) == "function" then
    m.then_ = spec.then_
  else
    -- then_ : m a -> (a -> b) -> m b  (fmap via bind+unit)
    function m.then_(ma, f)
      return m.bind(ma, function(a)
        return m.unit(f(a))
      end)
    end
  end

  -- Convenience aliases
  m.return_ = m.unit
  m.pure = m.unit
  m.fmap = m.then_
  m.map = m.then_

  -- Module call: Maybe(x) ≡ Maybe.unit(x)
  setmetatable(m, {
    __call = function(_, x)
      return m.unit(x)
    end,
  })

  return m
end

return {
  makeMonad = makeMonad,
}
