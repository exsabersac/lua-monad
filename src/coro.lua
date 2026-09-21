-- coro.lua — 基于 Cont 的 CPS 协程（单路，非 Lua 原生 coroutine）
--
-- 三层关系（详见 docs/设计说明.md / docs/CPS设计与原理.md）：
--   1. Cont r a          — 续延单子本身
--   2. 答案类型 Answer   — Done | Yielded | Stopped | Aborted | Failed，作为 Cont 的 r
--   3. Coro API          — yield / stop / abort / fail / start / resume / step / run / collect
--
-- Answer 形状：
--   Done    { tag = "done",    value }
--   Yielded { tag = "yielded", value, cont }  -- cont 是「恢复时收到的值 → Answer」
--   Stopped { tag = "stopped", reason? }      -- 主动停止 / 取消，不调用续延
--   Aborted { tag = "aborted", reason? }      -- 异常中止（≠ stop）；join/when_all 视为失败传播
--   Failed  { tag = "failed",  error }        -- 管道级失败，不调用续延
--
-- stop vs abort（对齐 tabMachine 语义子集）：
--   · stop  — 合作式停止；父 join/when_all 得到 Stopped（非成功值）
--   · abort — 异常中止；父 join/when_all 得到 Aborted（非成功值；不算 join 成功）
--   · session cancel / force_stop 仍走 Stopped（取消），经 Yielded.abort 跑 iquit/finally
--
-- yield(v) 不调用当前续延，而是把续延本身装进 Yielded 返回；
-- stop / abort / fail 同样不调用 k，直接返回终态答案（中止管道）。
-- resume 再把新值喂给 Yielded.cont。

local Cont = require("cont")

------------------------------------------------------------
-- Answer 构造与谓词
------------------------------------------------------------

local function Done(v)
  return { tag = "done", value = v }
end

local function Yielded(v, cont)
  return { tag = "yielded", value = v, cont = cont }
end

local function Stopped(reason)
  return { tag = "stopped", reason = reason }
end

local function Aborted(reason)
  return { tag = "aborted", reason = reason }
end

local function Failed(err)
  return { tag = "failed", error = err }
end

local function isDone(a)
  return type(a) == "table" and a.tag == "done"
end

local function isYielded(a)
  return type(a) == "table" and a.tag == "yielded"
end

local function isStopped(a)
  return type(a) == "table" and a.tag == "stopped"
end

local function isAborted(a)
  return type(a) == "table" and a.tag == "aborted"
end

local function isFailed(a)
  return type(a) == "table" and a.tag == "failed"
end

-- 终态（不再 resume）：Done | Stopped | Aborted | Failed
local function isTerminal(a)
  return isDone(a) or isStopped(a) or isAborted(a) or isFailed(a)
end

------------------------------------------------------------
-- Cont Answer 原语
------------------------------------------------------------

-- yield : a → Cont Answer b
-- 挂起并交出 v；之后 resume(y, b) 等价于把 b 交给当时的续延 k
local function yield(v)
  return Cont.wrap(function(k)
    return Yielded(v, k)
  end)
end

-- stop : reason? → Cont Answer b
-- 中止管道：不调用当前续延 k，直接返回 Stopped
local function stop(reason)
  return Cont.wrap(function(_k)
    return Stopped(reason)
  end)
end

-- abort : reason? → Cont Answer b
-- 异常中止：不调用当前续延 k，直接返回 Aborted（join 不算成功）
local function abort(reason)
  return Cont.wrap(function(_k)
    return Aborted(reason)
  end)
end

-- fail : err → Cont Answer b
-- 失败中止：不调用当前续延 k，直接返回 Failed
local function fail(err)
  return Cont.wrap(function(_k)
    return Failed(err)
  end)
end

-- start : Cont Answer a → Answer
-- 顶层续延把最终值包成 Done；若 ma 已 stop/abort/fail，则直接得到对应 Answer
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

-- force_stop : Answer → reason → Answer
-- 若 Yielded 带 with_finally / with_iquit 注入的 abort，则跑 iquit→finally 再 Stopped；
-- 否则直接 Stopped。供 session cancel / 实体销毁使用，避免裸写 Stopped 跳过清理。
-- 注意：cancel 语义仍是 Stopped（不是 Aborted）；业务异常请用 Coro.abort / fx.abort。
local function force_stop(answer, reason)
  if isYielded(answer) and type(answer.abort) == "function" then
    return answer.abort(reason)
  end
  return Stopped(reason)
end

-- step : Answer → b → Answer
-- 安全驱动：Done / Stopped / Aborted / Failed 原样返回；Yielded 则 resume
local function step(answer, value)
  if isDone(answer) or isStopped(answer) or isAborted(answer) or isFailed(answer) then
    return answer
  end
  assert(isYielded(answer), "step: expected Done, Yielded, Stopped, Aborted, or Failed")
  return resume(answer, value)
end

------------------------------------------------------------
-- 驱动循环
------------------------------------------------------------

-- runEx : Cont Answer a → (yielded → resume_input) → status, payload
-- status ∈ "done" | "stopped" | "aborted" | "failed"
local function runEx(ma, handler)
  assert(type(handler) == "function", "runEx: handler must be a function")
  local answer = start(ma)
  while isYielded(answer) do
    local next_input = handler(answer.value)
    answer = resume(answer, next_input)
  end
  if isDone(answer) then
    return "done", answer.value
  elseif isStopped(answer) then
    return "stopped", answer.reason
  elseif isAborted(answer) then
    return "aborted", answer.reason
  elseif isFailed(answer) then
    return "failed", answer.error
  end
  error("runEx: unexpected answer tag=" .. tostring(answer and answer.tag), 2)
end

-- run : Cont Answer a → handler → final_value  |  nil, answer
-- 成功（Done）返回最终 value；Stopped/Aborted/Failed 返回 nil, answer
local function run(ma, handler)
  assert(type(handler) == "function", "run: handler must be a function")
  local answer = start(ma)
  while isYielded(answer) do
    local next_input = handler(answer.value)
    answer = resume(answer, next_input)
  end
  if isDone(answer) then
    return answer.value
  end
  if isStopped(answer) or isAborted(answer) or isFailed(answer) then
    return nil, answer
  end
  error("run: unexpected answer tag=" .. tostring(answer and answer.tag), 2)
end

-- collect : Cont Answer a → yields, final[, answer]
-- 记录每次 yield 载荷，resume 用 true；Stopped/Aborted/Failed 时 final 为 nil，第三返回值为 answer
local function collect(ma)
  local yields = {}
  local final, ans = run(ma, function(v)
    yields[#yields + 1] = v
    return true
  end)
  if ans ~= nil then
    return yields, nil, ans
  end
  return yields, final
end

return {
  Done = Done,
  Yielded = Yielded,
  Stopped = Stopped,
  Aborted = Aborted,
  Failed = Failed,
  isDone = isDone,
  isYielded = isYielded,
  isStopped = isStopped,
  isAborted = isAborted,
  isFailed = isFailed,
  isTerminal = isTerminal,
  yield = yield,
  stop = stop,
  abort = abort,
  fail = fail,
  start = start,
  resume = resume,
  force_stop = force_stop,
  step = step,
  run = run,
  runEx = runEx,
  collect = collect,
  Cont = Cont,
}
