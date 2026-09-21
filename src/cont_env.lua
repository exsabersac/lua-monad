-- cont_env.lua — Cont 专用「环境收集」组合（PLoop 风格的轻量替代）
--
-- 在 withEnv(body) 里，body 收到一张带 __newindex 的 env（常写作 _ENV）。
-- 凡通过 env 写入的**新函数**都会按「首次出现名」记入有序步骤表，最终折成：
--   composed(x) = Cont.unit(x) >> step1 >> step2 >> ... >> stepN
-- 无 ContPipe()、无 opt-in：收集默认开启。
--
-- 与 @mdo：mdo 是源码预处理（任意 monad 的 <- 绑定）；本模块是 Cont 运行时
-- 按定义顺序自动 >>，不依赖 PLoop，也不用 Lua 原生 coroutine / runDo。
--
-- 规则摘要：
--   1. 函数赋值 → 管道步骤；同名再赋 → 原地替换（保留首次出现次序）；可用 AfterStep/BeforeStep 拓扑重排。
--   2. 步骤可为普通 `a → b`：注册时自动 lift（非 Cont 返回值包 Cont.unit）；已是 Cont（mt 判定）则原样。
--   3. 非函数赋值 → 普通字段，不进管道（常量/表 ok）。
--   4. 助手：步内 local；或 `__Helper__()` / `__NotStep__()` 标注后再赋函数（存 env 但不进 >>；不 lift）。
--   5. 固定名 `init` / `__init__` 与属性 `__Init__`：非步骤；在管道前按定义序跑一遍（可改写输入；普通返回值亦经 Cont.unit）。
--   6. 固定名 `finally` / `__final__` 与属性 `__Finally__`：非步骤；在管道/协程会话退出时跑清理（忽略值时可返回 true 等普通值）。
--   7. 零步骤时 composed ≡ Cont.unit（恒等管道）；若仅有 init/finally 仍包一层生命周期。
--   8. 返回值为主；env.pipe / env.compose 指向同一 composed 便于自省。
--   9. body 返回后会对步骤表做快照；之后再改 env 不影响已返回的 composed。
--  10. 属性（`__Name__()`）排队，作用于**紧随其后**的那个函数赋值（PLoop 风格）；lift 在属性包装之前，故属性看到的是 Cont 步进。

local Cont = require("cont")

local cont_env = {}

------------------------------------------------------------
-- Cont 值判定与普通步进自动提升
------------------------------------------------------------
-- makeMonad 产出的 Cont 是带共享 mt 的代理表（通常有 _fn）。
local cont_mt = getmetatable(Cont.unit(nil))

local function is_cont(x)
  return type(x) == "table" and getmetatable(x) == cont_mt
end

--- Cont.is / Cont.isCont：对外识别 Cont 值（与 withEnv 提升规则一致）
function Cont.is(x)
  return is_cont(x)
end
Cont.isCont = Cont.is

--- 把 a→b 或 a→Cont 统一成 a→Cont；已是 Cont 则原样返回
local function lift_step(step)
  return function(a)
    local r = step(a)
    if is_cont(r) then
      return r
    end
    return Cont.unit(r)
  end
end

--- pending 是否把下一函数标成非管道步骤（helper / init / finally）
local function pending_marks_non_step(pending)
  for _, item in ipairs(pending) do
    if item.kind == "helper" or item.kind == "finally" or item.kind == "init" then
      return true
    end
  end
  return false
end

local DEFAULT_UNTIL_MAX = 1000

-- 属性名（不可被用户覆盖为步骤）
local ATTR_KEYS = {
  __Helper__ = true,
  __NotStep__ = true,
  __Wrap__ = true,
  __Before__ = true,
  __After__ = true,
  __Until__ = true,
  __Timeout__ = true,
  __Retry__ = true,
  __Require__ = true,
  __Trace__ = true,
  __AfterStep__ = true,
  __BeforeStep__ = true,
  __Catch__ = true,
  __Finally__ = true,
  __Init__ = true,
}

-- 固定名：写入 env 时自动视为 init / finally（非管道步骤）
local INIT_NAMES = { init = true, __init__ = true }
local FINALLY_NAMES = { finally = true, __final__ = true }

------------------------------------------------------------
-- 独立属性构造器：cont_env.attrs.__X__(...)(step) → new_step
-- （不依赖 withEnv；Helper 返回 sentinel，见下）
------------------------------------------------------------
local function wrap_before(pre)
  assert(type(pre) == "function", "__Before__: pre must be a function")
  return function(step)
    assert(type(step) == "function", "__Before__: step must be a function")
    return function(x)
      return pre(x) >> step
    end
  end
end

local function wrap_after(post)
  assert(type(post) == "function", "__After__: post must be a function")
  return function(step)
    assert(type(step) == "function", "__After__: step must be a function")
    return function(x)
      return step(x) >> post
    end
  end
end

local function wrap_until(pred, max)
  assert(type(pred) == "function", "__Until__: pred must be a function")
  max = max or DEFAULT_UNTIL_MAX
  assert(type(max) == "number" and max >= 1, "__Until__: max must be a positive number")
  return function(step)
    assert(type(step) == "function", "__Until__: step must be a function")
    return function(x)
      local function go(v, n)
        if n > max then
          error("__Until__: exceeded max iterations (" .. tostring(max) .. ")", 2)
        end
        return step(v) >> function(a)
          if pred(a) then
            return Cont.unit(a)
          else
            return go(a, n + 1)
          end
        end
      end
      return go(x, 1)
    end
  end
end

local function wrap_wrap(wrapper)
  assert(type(wrapper) == "function", "__Wrap__: wrapper must be a function")
  return function(step)
    assert(type(step) == "function", "__Wrap__: step must be a function")
    local out = wrapper(step)
    assert(type(out) == "function", "__Wrap__: wrapper(step) must return a function")
    return out
  end
end

-- 合作式超时：步完成后用 os.clock 检查；无法打断同步步中途
local function wrap_timeout(secs, on_timeout)
  assert(type(secs) == "number" and secs >= 0, "__Timeout__: secs must be a non-negative number")
  if on_timeout ~= nil then
    assert(type(on_timeout) == "function", "__Timeout__: on_timeout must be a function or nil")
  end
  return function(step)
    assert(type(step) == "function", "__Timeout__: step must be a function")
    return function(x)
      local t0 = os.clock()
      return step(x) >> function(a)
        local elapsed = os.clock() - t0
        if elapsed > secs then
          if on_timeout then
            return on_timeout(a, elapsed)
          end
          return Cont.unit({ tag = "timeout", value = a, elapsed = elapsed })
        end
        return Cont.unit(a)
      end
    end
  end
end

-- pred(a) 为真则需重试；始终用原始 x 再跑 step，最多 n 次；最后仍 pred 则返回该 a
local function wrap_retry(n, pred)
  assert(type(n) == "number" and n >= 1 and n == math.floor(n), "__Retry__: n must be a positive integer")
  assert(type(pred) == "function", "__Retry__: pred must be a function")
  return function(step)
    assert(type(step) == "function", "__Retry__: step must be a function")
    return function(x)
      local function go(attempt)
        return step(x) >> function(a)
          if not pred(a) then
            return Cont.unit(a)
          elseif attempt >= n then
            return Cont.unit(a)
          else
            return go(attempt + 1)
          end
        end
      end
      return go(1)
    end
  end
end

-- 步前校验：不满足 pred(x) 则 on_fail(x) 或 {tag="rejected", value=x}
local function wrap_require(pred, on_fail)
  assert(type(pred) == "function", "__Require__: pred must be a function")
  if on_fail ~= nil then
    assert(type(on_fail) == "function", "__Require__: on_fail must be a function or nil")
  end
  return function(step)
    assert(type(step) == "function", "__Require__: step must be a function")
    return function(x)
      if not pred(x) then
        if on_fail then
          return on_fail(x)
        end
        return Cont.unit({ tag = "rejected", value = x })
      end
      return step(x)
    end
  end
end

-- 前后 print，不改变值；label 可选
local function wrap_trace(label)
  if label ~= nil then
    assert(type(label) == "string" or type(label) == "number", "__Trace__: label must be string/number or nil")
  end
  local tag = label ~= nil and tostring(label) or "trace"
  return function(step)
    assert(type(step) == "function", "__Trace__: step must be a function")
    return function(x)
      print(string.format("[%s] before: %s", tag, tostring(x)))
      return step(x) >> function(a)
        print(string.format("[%s] after: %s", tag, tostring(a)))
        return Cont.unit(a)
      end
    end
  end
end

-- 步骤顺序约束（不包装函数；独立 API 返回描述符；withEnv 内排队）
local function make_after_step(name)
  assert(type(name) == "string", "__AfterStep__: name must be a string")
  return { __attr_after_step = name }
end

local function make_before_step(name)
  assert(type(name) == "string", "__BeforeStep__: name must be a string")
  return { __attr_before_step = name }
end

-- 用 Cont.catch 包住步骤产出的 Cont：步内 Cont.throw / Lua error 交给 handler
local function wrap_catch(handler)
  assert(type(handler) == "function", "__Catch__: handler must be a function")
  return function(step)
    assert(type(step) == "function", "__Catch__: step must be a function")
    return function(x)
      return Cont.catch(step(x), handler)
    end
  end
end

------------------------------------------------------------
-- init / finally 生命周期（Cont 层；Coro Answer 感知）
------------------------------------------------------------
-- finally(outcome) → Cont|value
--   outcome = { status="done", value=a }
--            | { status="failed", error=e }
--            | { status="stopped", reason=r }
-- init(x) → Cont|value：可改写进入管道的输入；普通值经 Cont.unit 包装。
--
-- 清理失败教学规则：cleanup 若 Cont.throw / 返回 Failed，则**覆盖**原结果为 Failed；
-- 成功清理后传播原 Done 值 / Stopped / Failed。

local function ensure_cont(x)
  if x == nil then
    return Cont.unit(true)
  end
  if is_cont(x) then
    return x
  end
  if type(x) == "function" then
    -- 裸 CPS 函数（少见）→ wrap；与步骤 lift 不同，init/finally 仍兼容
    return Cont.wrap(x)
  end
  return Cont.unit(x)
end

local function answer_tag(x)
  if type(x) == "table" then
    return x.tag
  end
  return nil
end

--- with_finally(ma, cleanup) → Cont
-- 在 Cont 正常成功、Cont.throw（经本层 catch）、以及 Coro Answer 的
-- Done|Stopped|Failed 终态上调用 cleanup；Yielded 时推迟到真正终态。
function cont_env.with_finally(ma, cleanup)
  assert(type(cleanup) == "function", "with_finally: cleanup must be a function")

  return Cont.wrap(function(outer_k)
    local cleaned = false
    local fail_handling = false

    local function drain_cleanup_result(res, after)
      local tag = answer_tag(res)
      if type(res) == "table" and res.__finally_continue then
        return after()
      end
      if tag == "yielded" then
        return {
          tag = "yielded",
          value = res.value,
          cont = function(b)
            return drain_cleanup_result(res.cont(b), after)
          end,
        }
      end
      if tag == "failed" or tag == "stopped" then
        -- 清理自身终态覆盖原结果
        return res
      end
      if tag == "done" then
        return after()
      end
      return after()
    end

    local function run_cleanup_then(outcome, after)
      if cleaned then
        return after()
      end
      cleaned = true
      local cu = ensure_cont(cleanup(outcome))
      -- cleanup 内 Cont.throw → Failed 覆盖
      local protected = Cont.catch(cu, function(err)
        return Cont.wrap(function(_k)
          return { tag = "failed", error = err }
        end)
      end)
      local res = Cont.unwrap(protected)(function(_v)
        return { __finally_continue = true }
      end)
      return drain_cleanup_result(res, after)
    end

    local function wrap_result(res)
      local tag = answer_tag(res)
      if tag == "yielded" then
        return {
          tag = "yielded",
          value = res.value,
          cont = function(b)
            return wrap_result(res.cont(b))
          end,
        }
      end
      if tag == "stopped" then
        return run_cleanup_then({ status = "stopped", reason = res.reason }, function()
          return res
        end)
      end
      if tag == "failed" then
        return run_cleanup_then({ status = "failed", error = res.error }, function()
          return res
        end)
      end
      if tag == "done" then
        -- 成功路径通常已在 outer_k 前清理；此处兜底（例如内层已包成 Done）
        return run_cleanup_then({ status = "done", value = res.value }, function()
          return res
        end)
      end
      return res
    end

    local body = Cont.catch(ma, function(err)
      -- Cont.catch 在 handler 再 Cont.throw 且无外层时，pcall 会重入 handler；
      -- 用 fail_handling 直接 error，避免死循环。
      if fail_handling then
        error("uncaught Cont.throw: " .. tostring(err), 0)
      end
      fail_handling = true
      return Cont.wrap(function(k)
        return run_cleanup_then({ status = "failed", error = err }, function()
          return Cont.unwrap(Cont.throw(err))(k)
        end)
      end)
    end)

    local res = Cont.unwrap(body)(function(a)
      return run_cleanup_then({ status = "done", value = a }, function()
        return outer_k(a)
      end)
    end)
    return wrap_result(res)
  end)
end

--- init_finally(ma, init?, cleanup?) → Cont
-- init() → Cont|value，先跑完再执行 ma；cleanup 同 with_finally。
-- 若只需其一，另一个传 nil。
function cont_env.init_finally(ma, init, cleanup)
  local m = ma
  if init ~= nil then
    assert(type(init) == "function", "init_finally: init must be a function or nil")
    m = Cont.bind(ensure_cont(init()), function(_)
      return ma
    end)
  end
  if cleanup ~= nil then
    assert(type(cleanup) == "function", "init_finally: cleanup must be a function or nil")
    m = cont_env.with_finally(m, cleanup)
  end
  return m
end

--- 组合 a→Cont：先 inits（定义序，可改写 x），再 steps，退出时 cleanups。
local function compose_lifecycle(order, steps, inits, cleanups)
  return function(x)
    local m = Cont.unit(x)
    for _, item in ipairs(inits) do
      local fn = item.fn
      m = m >> function(v)
        return ensure_cont(fn(v))
      end
    end
    for _, name in ipairs(order) do
      local step = steps[name]
      if type(step) == "function" then
        m = m >> step
      end
    end
    if #cleanups == 0 then
      return m
    end
    local cleanup_fns = cleanups
    return cont_env.with_finally(m, function(outcome)
      local c = Cont.unit(true)
      for _, item in ipairs(cleanup_fns) do
        local fn = item.fn
        c = c >> function(_)
          return ensure_cont(fn(outcome))
        end
      end
      return c
    end)
  end
end

local function upsert_named(list, key, fn)
  for i, item in ipairs(list) do
    if item.name == key then
      list[i] = { name = key, fn = fn }
      return
    end
  end
  list[#list + 1] = { name = key, fn = fn }
end

local function remove_named(list, key)
  for i = #list, 1, -1 do
    if list[i].name == key then
      table.remove(list, i)
      break
    end
  end
end

-- Helper sentinel：独立使用时标记「非步骤」；withEnv 内用队列 flag
local HELPER_SENTINEL = { __attr_helper = true }
local FINALLY_SENTINEL = { __attr_finally = true }
local INIT_SENTINEL = { __attr_init = true }

cont_env.attrs = {
  --- 标记下一函数为助手（独立 API 返回 sentinel；env 内排队）
  __Helper__ = function()
    return HELPER_SENTINEL
  end,
  __NotStep__ = function()
    return HELPER_SENTINEL
  end,
  --- 标记下一函数为 finally 清理（非步骤；会话退出时跑）
  __Finally__ = function()
    return FINALLY_SENTINEL
  end,
  --- 标记下一函数为 init（非步骤；管道前跑，可改写输入）
  __Init__ = function()
    return INIT_SENTINEL
  end,
  --- __Wrap__(wrapper)(step) → new_step
  __Wrap__ = wrap_wrap,
  --- __Before__(pre)(step) → λx. pre(x) >> step
  __Before__ = wrap_before,
  --- __After__(post)(step) → λx. step(x) >> post
  __After__ = wrap_after,
  --- __Until__(pred[, max])(step) → 循环直到 pred；默认 max=1000
  __Until__ = wrap_until,
  --- __Timeout__(secs[, on_timeout])(step) → 合作式超时（步后检查 os.clock）
  __Timeout__ = wrap_timeout,
  --- __Retry__(n, pred)(step) → pred(a) 则用原 x 重试，最多 n 次
  __Retry__ = wrap_retry,
  --- __Require__(pred[, on_fail])(step) → 步前校验 x
  __Require__ = wrap_require,
  --- __Trace__([label])(step) → 前后 print，值不变
  __Trace__ = wrap_trace,
  --- __AfterStep__(name) → 描述符；withEnv 内把下一步排到 name 之后
  __AfterStep__ = make_after_step,
  --- __BeforeStep__(name) → 描述符；withEnv 内把下一步排到 name 之前
  __BeforeStep__ = make_before_step,
  --- __Catch__(handler)(step) → Cont.catch(step(x), handler)
  __Catch__ = wrap_catch,
  -- __Finally__ / __Init__ 见上（sentinel；独立调用不包装 step）
}

cont_env.DEFAULT_UNTIL_MAX = DEFAULT_UNTIL_MAX

-- 按有序名表 + name→fn 映射折成 a → Cont r z
local function compose_steps(order, steps)
  return function(x)
    local m = Cont.unit(x)
    for _, name in ipairs(order) do
      local step = steps[name]
      if type(step) == "function" then
        m = m >> step
      end
    end
    return m
  end
end

--- 从 pending 队列折叠包装器到 value
-- 返回 new_fn, is_helper, is_finally, is_init, after_list, before_list
local function apply_pending(pending, value)
  local is_helper = false
  local is_finally = false
  local is_init = false
  local fn = value
  local after_list = {}
  local before_list = {}
  for _, item in ipairs(pending) do
    if item.kind == "helper" then
      is_helper = true
    elseif item.kind == "finally" then
      is_finally = true
    elseif item.kind == "init" then
      is_init = true
    elseif item.kind == "wrap" then
      fn = item.apply(fn)
    elseif item.kind == "after_step" then
      after_list[#after_list + 1] = item.name
    elseif item.kind == "before_step" then
      before_list[#before_list + 1] = item.name
    end
  end
  return fn, is_helper, is_finally, is_init, after_list, before_list
end

--- 构造挂到 env 上的属性构造器（写入 pending）
local function make_env_attr_ctors(pending)
  local function queue_helper()
    pending[#pending + 1] = { kind = "helper" }
  end

  local function queue_finally()
    pending[#pending + 1] = { kind = "finally" }
  end

  local function queue_init()
    pending[#pending + 1] = { kind = "init" }
  end

  return {
    __Helper__ = function()
      queue_helper()
    end,
    __NotStep__ = function()
      queue_helper()
    end,
    __Finally__ = function()
      queue_finally()
    end,
    __Init__ = function()
      queue_init()
    end,
    __Wrap__ = function(wrapper)
      local apply = wrap_wrap(wrapper)
      pending[#pending + 1] = { kind = "wrap", apply = apply }
    end,
    __Before__ = function(pre)
      local apply = wrap_before(pre)
      pending[#pending + 1] = { kind = "wrap", apply = apply }
    end,
    __After__ = function(post)
      local apply = wrap_after(post)
      pending[#pending + 1] = { kind = "wrap", apply = apply }
    end,
    __Until__ = function(pred, max)
      local apply = wrap_until(pred, max)
      pending[#pending + 1] = { kind = "wrap", apply = apply }
    end,
    __Timeout__ = function(secs, on_timeout)
      local apply = wrap_timeout(secs, on_timeout)
      pending[#pending + 1] = { kind = "wrap", apply = apply }
    end,
    __Retry__ = function(n, pred)
      local apply = wrap_retry(n, pred)
      pending[#pending + 1] = { kind = "wrap", apply = apply }
    end,
    __Require__ = function(pred, on_fail)
      local apply = wrap_require(pred, on_fail)
      pending[#pending + 1] = { kind = "wrap", apply = apply }
    end,
    __Trace__ = function(label)
      local apply = wrap_trace(label)
      pending[#pending + 1] = { kind = "wrap", apply = apply }
    end,
    __AfterStep__ = function(name)
      assert(type(name) == "string", "__AfterStep__: name must be a string")
      pending[#pending + 1] = { kind = "after_step", name = name }
    end,
    __BeforeStep__ = function(name)
      assert(type(name) == "string", "__BeforeStep__: name must be a string")
      pending[#pending + 1] = { kind = "before_step", name = name }
    end,
    __Catch__ = function(handler)
      local apply = wrap_catch(handler)
      pending[#pending + 1] = { kind = "wrap", apply = apply }
    end,
  }
end

local function clear_pending(pending)
  for i = #pending, 1, -1 do
    pending[i] = nil
  end
end

local function remove_from_order(order, key)
  for i = #order, 1, -1 do
    if order[i] == key then
      table.remove(order, i)
      break
    end
  end
end

--- Kahn 拓扑排序；无边时保持定义序；平局按 def_index；环或缺目标则 error
local function resolve_step_order(order, constraints)
  local n = #order
  if n == 0 then
    return order
  end

  local index = {}
  for i, name in ipairs(order) do
    index[name] = i
  end

  -- 收集边 u -> v（u 在 v 前），并校验目标存在
  local edges = {} -- list of {u, v}
  local adj = {}
  local indeg = {}
  for _, name in ipairs(order) do
    adj[name] = {}
    indeg[name] = 0
  end

  local function add_edge(u, v, via, target)
    if index[target] == nil then
      error(
        "withEnv: "
          .. via
          .. " target '"
          .. tostring(target)
          .. "' is not a registered step",
        0
      )
    end
    if u == v then
      error(
        "withEnv: step order cycle involving '" .. tostring(u) .. "' (self-constraint)",
        0
      )
    end
    adj[u][#adj[u] + 1] = v
    indeg[v] = indeg[v] + 1
    edges[#edges + 1] = { u, v }
  end

  for _, name in ipairs(order) do
    local c = constraints[name]
    if c then
      for _, a in ipairs(c.after or {}) do
        -- AfterStep(A) on F => A -> F
        add_edge(a, name, "__AfterStep__", a)
      end
      for _, b in ipairs(c.before or {}) do
        -- BeforeStep(B) on F => F -> B
        add_edge(name, b, "__BeforeStep__", b)
      end
    end
  end

  -- 若无边，直接返回定义序
  if #edges == 0 then
    return order
  end

  -- 就绪集：按定义序挑最小 index
  local function pick_ready()
    local best, best_i = nil, nil
    for _, name in ipairs(order) do
      if indeg[name] == 0 then
        local i = index[name]
        if best_i == nil or i < best_i then
          best, best_i = name, i
        end
      end
    end
    return best
  end

  -- 标记已输出：用 indeg=-1
  local result = {}
  for _ = 1, n do
    local u = pick_ready()
    if u == nil then
      error("withEnv: step order cycle among AfterStep/BeforeStep constraints", 0)
    end
    result[#result + 1] = u
    indeg[u] = -1
    for _, v in ipairs(adj[u]) do
      if indeg[v] >= 0 then
        indeg[v] = indeg[v] - 1
      end
    end
  end
  return result
end

--- withEnv(body) → composed
-- body(env)：在 env 上用 `function name(...) ... end` 或 `env.name = fn` 定义步骤。
-- 步骤可为普通 a→b（自动 Cont.unit 提升）或 a→Cont（mt 判定，原样）。
-- 可用 `__Helper__()` / `__Wrap__` / `__Before__` / `__After__` / `__Until__` / `__Timeout__` /
-- `__Retry__` / `__Require__` / `__Trace__` / `__Catch__` / `__AfterStep__` / `__BeforeStep__` /
-- `__Init__` / `__Finally__` 标注下一函数。
-- 固定名 `init`/`__init__`、`finally`/`__final__` 亦为非步骤生命周期钩子（返回值亦可为普通值）。
-- 返回 composed：a → Cont r z；顺序为 inits → steps →（退出时）cleanups。
function cont_env.withEnv(body)
  assert(type(body) == "function", "withEnv: body must be a function")

  local order = {} -- 首次出现的步骤名，保序
  local steps = {} -- name → step 函数（仅管道步骤）
  local constraints = {} -- name → { after = {..}, before = {..} }
  local inits = {} -- { {name=, fn=}, ... } 定义序
  local cleanups = {} -- { {name=, fn=}, ... } 定义序
  local data = {} -- 普通字段存储（含助手/init/finally 函数、最终 pipe/compose）
  local pending = {} -- 排队中的属性 applicators / helper flags / 顺序约束
  local attr_ctors = make_env_attr_ctors(pending)

  local env = {}
  local mt = {
    __index = function(_, key)
      local v = rawget(data, key)
      if v ~= nil then
        return v
      end
      return attr_ctors[key]
    end,
    __newindex = function(_, key, value)
      if ATTR_KEYS[key] then
        error("withEnv: cannot overwrite attribute constructor '" .. tostring(key) .. "'", 2)
      end

      if type(value) == "function" then
        local is_helper, is_finally, is_init = false, false, false
        local after_list, before_list = {}, {}

        -- 管道步骤：先 lift，再折属性，使 __Before__/__Trace__ 等看到 Cont 步进。
        -- helper / init / finally 不按步骤 lift（init/finally 返回值由 ensure_cont 处理）。
        local non_step = INIT_NAMES[key]
          or FINALLY_NAMES[key]
          or pending_marks_non_step(pending)
        if not non_step then
          value = lift_step(value)
        end

        if #pending > 0 then
          value, is_helper, is_finally, is_init, after_list, before_list =
            apply_pending(pending, value)
          clear_pending(pending)
        end

        -- 固定名优先视为 init / finally
        if INIT_NAMES[key] then
          is_init = true
        end
        if FINALLY_NAMES[key] then
          is_finally = true
        end

        local function strip_from_steps()
          if steps[key] ~= nil then
            steps[key] = nil
            remove_from_order(order, key)
          end
          constraints[key] = nil
        end

        if is_finally then
          strip_from_steps()
          remove_named(inits, key)
          upsert_named(cleanups, key, value)
          rawset(data, key, value)
        elseif is_init then
          strip_from_steps()
          remove_named(cleanups, key)
          upsert_named(inits, key, value)
          rawset(data, key, value)
        elseif is_helper then
          -- 存到 data，但不进管道；若曾是步骤则移除
          strip_from_steps()
          remove_named(inits, key)
          remove_named(cleanups, key)
          rawset(data, key, value)
        else
          remove_named(inits, key)
          remove_named(cleanups, key)
          if steps[key] == nil then
            -- 若此前是 helper-only，不算「首次步骤」以外的特殊情况：直接加入 order
            order[#order + 1] = key
          end
          steps[key] = value
          -- 每次（重）定义都更新顺序约束（无 After/BeforeStep 则清空）
          constraints[key] = { after = after_list, before = before_list }
          rawset(data, key, value)
        end
      else
        -- 非函数：若有未消耗属性 → 报错（必须紧跟函数）
        if #pending > 0 then
          clear_pending(pending)
          error(
            "withEnv: pending attribute(s) require a following function assignment, got "
              .. type(value)
              .. " for key '"
              .. tostring(key)
              .. "'",
            2
          )
        end
        -- 非函数：不当作步骤；若曾是步骤/init/finally 名则移除
        if steps[key] ~= nil then
          steps[key] = nil
          remove_from_order(order, key)
          constraints[key] = nil
        end
        remove_named(inits, key)
        remove_named(cleanups, key)
        rawset(data, key, value)
      end
    end,
  }
  setmetatable(env, mt)

  body(env)

  if #pending > 0 then
    clear_pending(pending)
    error("withEnv: pending attribute(s) at end of body with no following function", 2)
  end

  -- 按 AfterStep/BeforeStep 拓扑重排（无约束则保持定义序）
  order = resolve_step_order(order, constraints)

  -- 快照：composed 固定为 body 结束时的步骤 / init / finally 序列
  local order_snap = {}
  local steps_snap = {}
  for i, name in ipairs(order) do
    order_snap[i] = name
    steps_snap[name] = steps[name]
  end
  local inits_snap = {}
  for i, item in ipairs(inits) do
    inits_snap[i] = { name = item.name, fn = item.fn }
  end
  local cleanups_snap = {}
  for i, item in ipairs(cleanups) do
    cleanups_snap[i] = { name = item.name, fn = item.fn }
  end

  local composed
  if #inits_snap == 0 and #cleanups_snap == 0 then
    composed = compose_steps(order_snap, steps_snap)
  else
    composed = compose_lifecycle(order_snap, steps_snap, inits_snap, cleanups_snap)
  end

  -- rawset 避免 pipe/compose 被当成新步骤
  rawset(data, "pipe", composed)
  rawset(data, "compose", composed)

  return composed
end

-- 挂到 Cont，便于 Cont.withEnv / Cont.finally / Cont.init_finally；
-- cont.lua 另有延迟转发，避免循环 require。
Cont.withEnv = cont_env.withEnv
Cont.finally = cont_env.with_finally
Cont.init_finally = cont_env.init_finally

return cont_env
