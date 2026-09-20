-- Generic monad constructor.
-- makeMonad({ unit = f, bind = g [, then_ = h] })
-- Returns a table `m` with unit, bind, and then_ (default: bind then map via unit).

local function makeMonad(spec)
  assert(type(spec) == "table", "makeMonad: spec must be a table")
  assert(type(spec.unit) == "function", "makeMonad: unit required")
  assert(type(spec.bind) == "function", "makeMonad: bind required")

  local m = {
    unit = spec.unit,
    bind = spec.bind,
  }

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

  return m
end

return {
  makeMonad = makeMonad,
}
