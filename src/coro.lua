-- coro.lua — 基于 Cont 的 CPS 协程（单路，非 Lua 原生 coroutine）
--
-- 三层关系（详见 docs/设计说明.md）：
--   1. Cont r a          — 续延单子本身
--   2. 答案类型 Answer   — Done | Yielded，作为 Cont 的 r
--   3. Coro API          — yield / start / resume / step / run / collect
--
-- Answer 形状：
--   Done    { tag = "done",    value }
--   Yielded { tag = "yielded", value, cont }  -- cont 是「恢复时收到的值 → Answer」
--
-- yield(v) 不调用当前续延，而是把续延本身装进 Yielded 返回；
-- resume 再把新值喂给该 cont。教学上对应「yield = 捕获当前续延」。

local Cont = require("cont")

local function Done(v)
  return { tag = "done", value = v }
end

local function Yielded(v, cont)
  return { tag = "yielded", value = v, cont = cont }
end

local function isDone(a)
  return type(a) == "table" and a.tag == "done"
end

local function isYielded(a)
  return type(a) == "table" and a.tag == "yielded"
end

-- yield : a → Cont Answer b
-- 挂起并交出 v；之后 resume(y, b) 等价于把 b 交给当时的续延 k
local function yield(v)
  return Cont.wrap(function(k)
    return Yielded(v, k)
  end)
end

-- start : Cont Answer a → Answer
-- 顶层续延把最终值包成 Done
local function start(ma)
  return Cont.runCont(ma, function(a)
    return Done(a)
  end)
end

-- resume : Yielded → b → Answer
local function resume(y, b)
  assert(isYielded(y), "resume: expected Yielded")
  return y.cont(b)
end

-- step : Answer → b → Answer
-- 安全驱动助手：若已是 Done 则原样返回；若是 Yielded 则 resume。
-- 便于写统一的「推进一步」循环，而不必先判断 tag。
local function step(answer, value)
  if isDone(answer) then
    return answer
  end
  assert(isYielded(answer), "step: expected Done or Yielded")
  return resume(answer, value)
end

-- run : Cont Answer a → (yielded_value → resume_input) → final_value
-- 启动 ma；每当 Yielded，把交出的值交给 handler，用 handler 的返回值 resume；
-- 直到 Done，返回最终 value。
local function run(ma, handler)
  assert(type(handler) == "function", "run: handler must be a function")
  local answer = start(ma)
  while isYielded(answer) do
    local next_input = handler(answer.value)
    answer = resume(answer, next_input)
  end
  assert(isDone(answer), "run: expected Done at end")
  return answer.value
end

-- collect : Cont Answer a → yields, final
-- 用 handler 记录每次 yield 的载荷到列表，并以 true（若无则 nil）作为 resume 输入；
-- 返回 yields（数组）, final（Done 的 value）。
local function collect(ma)
  local yields = {}
  local final = run(ma, function(v)
    yields[#yields + 1] = v
    return true
  end)
  return yields, final
end

return {
  Done = Done,
  Yielded = Yielded,
  isDone = isDone,
  isYielded = isYielded,
  yield = yield,
  start = start,
  resume = resume,
  step = step,
  run = run,
  collect = collect,
  Cont = Cont,
}
