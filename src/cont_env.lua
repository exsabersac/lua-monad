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
--   1. 函数赋值 → 管道步骤；同名再赋 → 原地替换（保留首次出现次序）。
--   2. 非函数赋值 → 普通字段，不进管道（常量/表 ok）。
--   3. 助手函数请写在某步内部的 local function，勿挂到 env（否则也会成步骤）。
--   4. 零步骤时 composed ≡ Cont.unit（恒等管道）。
--   5. 返回值为主；env.pipe / env.compose 指向同一 composed 便于自省。
--   6. body 返回后会对步骤表做快照；之后再改 env 不影响已返回的 composed。

local Cont = require("cont")

local cont_env = {}

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

--- withEnv(body) → composed
-- body(env)：在 env 上用 `function name(...) ... end` 或 `env.name = fn` 定义步骤。
-- 返回 composed：a → Cont r z，等价于 foldl (>>) Cont.unit（定义序；同名替换保序）。
function cont_env.withEnv(body)
  assert(type(body) == "function", "withEnv: body must be a function")

  local order = {} -- 首次出现的步骤名，保序
  local steps = {} -- name → step 函数
  local data = {} -- 普通字段存储（含最终 pipe/compose）

  local env = {}
  local mt = {
    __index = data,
    __newindex = function(_, key, value)
      if type(value) == "function" then
        if steps[key] == nil then
          order[#order + 1] = key
        end
        steps[key] = value
        rawset(data, key, value) -- 也允许 env.name 读回该函数
      else
        -- 非函数：不当作步骤；若曾是步骤名则从管道移除
        if steps[key] ~= nil then
          steps[key] = nil
          for i = #order, 1, -1 do
            if order[i] == key then
              table.remove(order, i)
              break
            end
          end
        end
        rawset(data, key, value)
      end
    end,
  }
  setmetatable(env, mt)

  body(env)

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
