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
--   2. 非函数赋值 → 普通字段，不进管道（常量/表 ok）。
--   3. 助手：步内 local；或 `__Helper__()` / `__NotStep__()` 标注后再赋函数（存 env 但不进 >>）。
--   4. 零步骤时 composed ≡ Cont.unit（恒等管道）。
--   5. 返回值为主；env.pipe / env.compose 指向同一 composed 便于自省。
--   6. body 返回后会对步骤表做快照；之后再改 env 不影响已返回的 composed。
--   7. 属性（`__Name__()`）排队，作用于**紧随其后**的那个函数赋值（PLoop 风格）。

local Cont = require("cont")

local cont_env = {}

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
}

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

-- Helper sentinel：独立使用时标记「非步骤」；withEnv 内用队列 flag
local HELPER_SENTINEL = { __attr_helper = true }

cont_env.attrs = {
  --- 标记下一函数为助手（独立 API 返回 sentinel；env 内排队）
  __Helper__ = function()
    return HELPER_SENTINEL
  end,
  __NotStep__ = function()
    return HELPER_SENTINEL
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

--- 从 pending 队列折叠包装器到 value；返回 new_fn, is_helper, after_list, before_list
local function apply_pending(pending, value)
  local is_helper = false
  local fn = value
  local after_list = {}
  local before_list = {}
  for _, item in ipairs(pending) do
    if item.kind == "helper" then
      is_helper = true
    elseif item.kind == "wrap" then
      fn = item.apply(fn)
    elseif item.kind == "after_step" then
      after_list[#after_list + 1] = item.name
    elseif item.kind == "before_step" then
      before_list[#before_list + 1] = item.name
    end
  end
  return fn, is_helper, after_list, before_list
end

--- 构造挂到 env 上的属性构造器（写入 pending）
local function make_env_attr_ctors(pending)
  local function queue_helper()
    pending[#pending + 1] = { kind = "helper" }
  end

  return {
    __Helper__ = function()
      queue_helper()
    end,
    __NotStep__ = function()
      queue_helper()
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
-- 可用 `__Helper__()` / `__Wrap__` / `__Before__` / `__After__` / `__Until__` / `__Timeout__` /
-- `__Retry__` / `__Require__` / `__Trace__` / `__Catch__` / `__AfterStep__` / `__BeforeStep__` 标注下一函数。
-- 返回 composed：a → Cont r z，等价于 foldl (>>) Cont.unit（默认定义序；AfterStep/BeforeStep 拓扑重排）。
function cont_env.withEnv(body)
  assert(type(body) == "function", "withEnv: body must be a function")

  local order = {} -- 首次出现的步骤名，保序
  local steps = {} -- name → step 函数（仅管道步骤）
  local constraints = {} -- name → { after = {..}, before = {..} }
  local data = {} -- 普通字段存储（含助手函数、最终 pipe/compose）
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
        local is_helper = false
        local after_list, before_list = {}, {}
        if #pending > 0 then
          value, is_helper, after_list, before_list = apply_pending(pending, value)
          clear_pending(pending)
        end

        if is_helper then
          -- 存到 data，但不进管道；若曾是步骤则移除
          if steps[key] ~= nil then
            steps[key] = nil
            remove_from_order(order, key)
          end
          constraints[key] = nil
          rawset(data, key, value)
        else
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
        -- 非函数：不当作步骤；若曾是步骤名则从管道移除
        if steps[key] ~= nil then
          steps[key] = nil
          remove_from_order(order, key)
          constraints[key] = nil
        end
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

  -- 快照：composed 固定为 body 结束时的步骤序列
  local order_snap = {}
  local steps_snap = {}
  for i, name in ipairs(order) do
    order_snap[i] = name
    steps_snap[name] = steps[name]
  end
  local composed = compose_steps(order_snap, steps_snap)

  -- rawset 避免 pipe/compose 被当成新步骤
  rawset(data, "pipe", composed)
  rawset(data, "compose", composed)

  return composed
end

-- 挂到 Cont，便于 Cont.withEnv(...)；cont.lua 另有延迟转发，避免循环 require
Cont.withEnv = cont_env.withEnv

return cont_env
