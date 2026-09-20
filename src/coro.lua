-- coro.lua — 基于 Cont 的 CPS 协程（单路，非 Lua 原生 coroutine）
--
-- 三层关系（详见 docs/设计说明.md）：
--   1. Cont r a          — 续延单子本身
--   2. 答案类型 Answer   — Done | Yielded，作为 Cont 的 r
--   3. Coro API          — yield / start / resume，把挂起编码进 Answer
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

return {
  Done = Done,
  Yielded = Yielded,
  isDone = isDone,
  isYielded = isYielded,
  yield = yield,
  start = start,
  resume = resume,
  Cont = Cont,
}
