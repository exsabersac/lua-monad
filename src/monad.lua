-- monad.lua — 通用 Monad 工厂与元表符号糖
--
-- 对应 Haskell 的 Monad 类最小接口：
--   unit / return_ / pure  ≈  return / pure
--   bind                   ≈  (>>=)
--   then_ / fmap / map     ≈  fmap（默认由 bind+unit 导出）
--
-- makeMonad({ unit = f, bind = g [, then_ = h] }) 返回模块表 m。
-- 经 unit/bind 产出的「monadic 值」会挂上共享元表，从而支持：
--   ma >> f     →  __shr     →  m.bind(ma, f)          （Haskell >>=）
--   ma .. mb    →  __concat  →  丢弃 ma 结果，得到 mb  （Haskell >>）
--   m(x)        →  模块 __call →  m.unit(x)
--
-- 两种值形态：
--   表形（Maybe / List / Status）：直接 setmetatable 到值表上
--   函数形（Cont / State）：包成可调用代理 { _fn = f }，__call 转发；
--     对外仍可用 ma(args...)；runCont / runState 等通过 unwrap 取回真函数

local function makeMonad(spec)
  assert(type(spec) == "table", "makeMonad: spec must be a table")
  assert(type(spec.unit) == "function", "makeMonad: unit required")
  assert(type(spec.bind) == "function", "makeMonad: bind required")

  local m = {}
  -- 本 monad 实例的共享元表；unwrap 用 getmetatable(x) == mt 识别「本家」值
  local mt = {}

  -- 函数形代理 → 取出底层闭包；表形或其它值原样返回
  local function unwrap(x)
    if type(x) == "table" and getmetatable(x) == mt and x._fn ~= nil then
      return x._fn
    end
    return x
  end

  -- 给原始 unit/bind 的返回值挂上元表，使其可参与 >> / ..
  -- 函数 → 代理表；已有本 mt 的表 → 不重复包；普通表 → setmetatable
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

  -- 顺序组合、丢弃左边结果（Haskell >>）；左边若短路（Nothing/Err）则右边不跑
  mt.__concat = function(ma, mb)
    return m.bind(ma, function(_)
      return mb
    end)
  end

  -- 仅函数形代理可调用：把参数转发给 _fn（State(s)、Cont(k)）
  mt.__call = function(ma, ...)
    local fn = ma._fn
    assert(type(fn) == "function", "monad value is not callable")
    return fn(...)
  end

  local raw_unit = spec.unit
  local raw_bind = spec.bind

  -- 对外 unit：先跑用户提供的 raw_unit，再 wrap，保证返回值带符号糖
  function m.unit(a)
    return wrap(raw_unit(a))
  end

  -- 对外 bind：进入 raw_bind 前 unwrap；用户 f 返回的值也 unwrap，
  -- 这样 raw_bind 始终看到「裸」表或函数，最后再 wrap 一次统一出口形态
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
    -- then_ : m a → (a → b) → m b   （fmap = bind ∘ unit）
    function m.then_(ma, f)
      return m.bind(ma, function(a)
        return m.unit(f(a))
      end)
    end
  end

  -- 别名：贴近 Haskell / 常见 FP 命名
  m.return_ = m.unit
  m.pure = m.unit
  m.fmap = m.then_
  m.map = m.then_

  -- 模块当构造器：Maybe(x) ≡ Maybe.unit(x)
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
