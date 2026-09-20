-- fx.lua — 教学用「同步写法 / 异步效果」层（建在 Cont + Coro 之上）
--
-- 核心思想：
--   1. 业务代码用 Cont.withEnv 写成看起来同步的步骤管道（open → wait → click → …）。
--   2. 真正的 wait / 网络 / 点击等「效果」并不在业务里执行，而是 Coro.yield 一条
--      Yielded 请求（{ kind=..., ... }）；外部解释器（fx.run 的 handlers）兑现后再 resume。
--   3. fx.stop / fx.fail 走 Coro Answer 终态（Stopped / Failed），中止管道而不再调 handler。
--   4. fx.when_all / fx.when_any 把并行组合编成 yield；由调度器时间轮并发驱动（对齐 C# WhenAll/WhenAny）。
--   5. 这不是真实网络/UI；默认 handlers 只是 mock，便于演示与测试。
--
-- 重要区分：
--   Cont 上的 Coro.yield ≠ Lua 原生 coroutine.yield。
--   Coro 用 Cont 编码答案类型 Done | Yielded | Stopped | Failed；业务 API 请走本模块 / Coro，
--   不要当原生协程 perform/runDo 用（本库主线已放弃 native perform/runDo）。
--
-- 依赖：cont.lua、coro.lua、fx_sched.lua

local Cont = require("cont")
local Coro = require("coro")
local Sched = require("fx_sched")

local fx = {}

------------------------------------------------------------
-- 效果原语
------------------------------------------------------------

-- wait : number → Cont Answer boolean
-- 挂起并交出 { kind="wait", seconds=... }；resume 后业务侧得到 true。
function fx.wait(seconds)
  seconds = seconds or 0
  return Coro.yield({ kind = "wait", seconds = seconds }) >> function(_resume)
    return Cont.unit(true)
  end
end

-- connect : string → table? → Cont Answer connection
-- 挂起并交出 { kind="connect", host=..., opts?=... }；resume 值即连接结果表。
function fx.connect(host, opts)
  local req = { kind = "connect", host = host }
  if opts ~= nil then
    req.opts = opts
  end
  return Coro.yield(req) >> function(conn)
    return Cont.unit(conn)
  end
end

-- click : any → Cont Answer click_result
-- 挂起并交出 { kind="click", target=... }；resume 值即点击结果表。
function fx.click(target)
  return Coro.yield({ kind = "click", target = target }) >> function(result)
    return Cont.unit(result)
  end
end

-- stop : reason? → Cont Answer b
-- 主动中止：返回 Coro.Stopped，不调用后续续延 / handler
function fx.stop(reason)
  return Coro.stop(reason)
end

-- fail : err → Cont Answer b
-- 管道级失败：返回 Coro.Failed（亦可写作 fx.throw 别名）
function fx.fail(err)
  return Coro.fail(err)
end

fx.throw = fx.fail -- 别名：与 Cont.throw 对照时可用 fx.throw 表示 Coro 层失败

------------------------------------------------------------
-- 并行组合子（Cont 层，可放进 withEnv 管道）
------------------------------------------------------------

-- when_all : { Cont Answer a, ... } → Cont Answer { a, ... }
-- yield { kind="when_all", tasks=mas }；fx.run / 并行调度器兑现后 resume 为 values 数组
function fx.when_all(mas)
  assert(type(mas) == "table", "fx.when_all: expected array of Cont Answer")
  return Coro.yield({ kind = "when_all", tasks = mas }) >> function(values)
    return Cont.unit(values)
  end
end

-- when_any : { Cont Answer a, ... } → Cont Answer { value=a, index=i }
-- yield { kind="when_any", tasks=mas }；第一个 Done 胜出，其余 cancelled
function fx.when_any(mas)
  assert(type(mas) == "table", "fx.when_any: expected array of Cont Answer")
  return Coro.yield({ kind = "when_any", tasks = mas }) >> function(winner)
    return Cont.unit(winner)
  end
end

-- 别名：教学文档里可与 join 对照
fx.join_all = fx.when_all
fx.join_any = fx.when_any

------------------------------------------------------------
-- 默认 mock handlers（可被 fx.run 的 handlers? 覆盖）
------------------------------------------------------------

local function busy_wait(seconds)
  Sched.busy_wait(seconds)
end

-- 默认处理器：打印日志 + mock 成功结果
-- kind="stop" 可选：若业务误用 Coro.yield{kind="stop"}，handlers 可识别；
-- 正常请用 fx.stop（直接 Stopped，不经过 handler）。
-- when_all / when_any 由 fx.run 特殊路径调度，不经本表。
local default_handlers = {
  wait = function(req)
    local secs = req.seconds or 0
    print(string.format("[fx] wait %.3fs …", secs))
    busy_wait(secs)
    print(string.format("[fx] wait done (%.3fs)", secs))
    return true
  end,
  connect = function(req)
    local host = req.host
    local latency = 0.012
    print(string.format("[fx] connect %s (mock latency=%.3fs)", tostring(host), latency))
    return { ok = true, host = host, latency = latency }
  end,
  click = function(req)
    local target = req.target
    print(string.format("[fx] click %s (mock)", tostring(target)))
    return { ok = true, target = target }
  end,
  -- 可选：把 yield{kind="stop"} 转成「业务侧收到后自行 stop」的信号；默认返回 reason
  stop = function(req)
    return { kind = "stop", reason = req.reason }
  end,
}

local function merge_handlers(overrides)
  local h = {}
  for k, v in pairs(default_handlers) do
    h[k] = v
  end
  if type(overrides) == "table" then
    for k, v in pairs(overrides) do
      h[k] = v
    end
  end
  return h
end

------------------------------------------------------------
-- 结果表与取消检测
------------------------------------------------------------

-- 结构化结果：
--   { ok=true,  value=v }
--   { ok=true,  values={...} }          -- run_parallel all
--   { ok=true,  value=v, index=i }      -- run_parallel any
--   { ok=false, stopped=true, reason= }
--   { ok=false, failed=true,  error= }
local function ok_result(v)
  return { ok = true, value = v }
end

local function stopped_result(reason)
  return { ok = false, stopped = true, reason = reason }
end

local function failed_result(err)
  return { ok = false, failed = true, error = err }
end

local function answer_to_result(answer)
  if Coro.isDone(answer) then
    return ok_result(answer.value)
  elseif Coro.isStopped(answer) then
    return stopped_result(answer.reason)
  elseif Coro.isFailed(answer) then
    return failed_result(answer.error)
  end
  error("fx: unexpected answer tag=" .. tostring(answer and answer.tag), 2)
end

-- opts.cancel : function()→boolean  或  token 表 { cancelled=false }
local function is_cancelled(cancel)
  if cancel == nil then
    return false
  end
  if type(cancel) == "function" then
    return not not cancel()
  end
  if type(cancel) == "table" then
    return not not cancel.cancelled
  end
  error("fx.run: opts.cancel must be function or {cancelled=...}", 2)
end

------------------------------------------------------------
-- 并行顶层 API
------------------------------------------------------------

-- run_parallel : { Cont Answer, ... } → handlers? → opts? → result
-- opts.mode = "all" | "any"（默认 "all"）
-- opts.cancel 与 fx.run 相同
-- all → { ok=true, values={v1,...} } | failed/stopped (+ index?)
-- any → { ok=true, value=v, index=i } | failed/stopped
function fx.run_parallel(tasks, handlers, opts)
  opts = opts or {}
  local mode = opts.mode or "all"
  local h = merge_handlers(handlers)
  -- 并行路径：wait 由时间轮处理，不走 handlers.wait 的串行 sleep
  -- 保留 connect/click 等；若用户自定义了 wait，仅在「非并行单任务」路径使用
  local sched_opts = {
    cancel = opts.cancel,
    verbose_wait = opts.verbose_wait,
  }
  return Sched.run_parallel(tasks, h, sched_opts, mode)
end

-- run_all : 教学友好别名（WhenAll）
function fx.run_all(tasks, handlers, opts)
  opts = opts or {}
  local o = {}
  for k, v in pairs(opts) do
    o[k] = v
  end
  o.mode = "all"
  return fx.run_parallel(tasks, handlers, o)
end

-- run_any : 教学友好别名（WhenAny）
function fx.run_any(tasks, handlers, opts)
  opts = opts or {}
  local o = {}
  for k, v in pairs(opts) do
    o[k] = v
  end
  o.mode = "any"
  return fx.run_parallel(tasks, handlers, o)
end

------------------------------------------------------------
-- run / try
------------------------------------------------------------

-- 兑现 when_all / when_any：调用调度器，成功则返回 resume 载荷；失败则返回 result 表
local function fulfill_parallel(req, handlers, opts)
  local mode = (req.kind == "when_any") and "any" or "all"
  local sub = Sched.run_parallel(req.tasks, handlers, {
    cancel = opts.cancel,
    verbose_wait = opts.verbose_wait,
  }, mode)
  if not sub.ok then
    return nil, sub
  end
  if mode == "all" then
    return sub.values, nil
  end
  return { value = sub.value, index = sub.index }, nil
end

-- run : Cont Answer a → handlers? → opts? → result
-- 每次 Yielded 在调用 handler **之前**检查 cancel；已取消则 Stopped("cancelled")。
-- when_all / when_any：走并行调度器（共享 handlers 与 cancel）。
-- 始终返回结构化 result 表（破坏性变更：旧代码请用 result.value）。
function fx.run(ma, handlers, opts)
  opts = opts or {}
  local h = merge_handlers(handlers)
  local cancel = opts.cancel

  local answer = Coro.start(ma)
  while Coro.isYielded(answer) do
    if is_cancelled(cancel) then
      return stopped_result("cancelled")
    end
    local req = answer.value
    assert(type(req) == "table" and req.kind ~= nil,
      "fx.run: expected yield payload table with .kind")

    if req.kind == "when_all" or req.kind == "when_any" then
      local payload, err_result = fulfill_parallel(req, h, opts)
      if err_result then
        return err_result
      end
      answer = Coro.resume(answer, payload)
    else
      local handler = h[req.kind]
      assert(handler, "fx.run: no handler for kind=" .. tostring(req.kind))
      local next_input = handler(req)
      answer = Coro.resume(answer, next_input)
    end
  end
  return answer_to_result(answer)
end

-- try : Cont Answer a → handlers? → opts → result
-- opts.on_fail(err) / opts.on_stop(reason) 可返回：
--   Cont Answer（再跑一遍解释器）| 普通值（包成 ok）| result 表（原样）| nil（保持原失败/停止）
function fx.try(ma, handlers, opts)
  opts = opts or {}
  local result = fx.run(ma, handlers, opts)
  if result.ok then
    return result
  end
  if result.failed and type(opts.on_fail) == "function" then
    local alt = opts.on_fail(result.error)
    if alt == nil then
      return result
    end
    if type(alt) == "table" and alt.ok ~= nil and (alt.value ~= nil or alt.values ~= nil or alt.stopped or alt.failed) then
      return alt
    end
    -- 若像 Cont/Coro 值（可调用或有 _fn），再跑
    if type(alt) == "function" or (type(alt) == "table" and alt._fn ~= nil) then
      return fx.run(alt, handlers, opts)
    end
    return ok_result(alt)
  end
  if result.stopped and type(opts.on_stop) == "function" then
    local alt = opts.on_stop(result.reason)
    if alt == nil then
      return result
    end
    if type(alt) == "table" and alt.ok ~= nil and (alt.value ~= nil or alt.values ~= nil or alt.stopped or alt.failed or alt.ok == false) then
      return alt
    end
    if type(alt) == "function" or (type(alt) == "table" and alt._fn ~= nil) then
      return fx.run(alt, handlers, opts)
    end
    return ok_result(alt)
  end
  return result
end

-- 暴露默认表便于测试/文档对照（请勿原地改；覆盖请传 fx.run 第二参）
fx.default_handlers = default_handlers
fx.ok_result = ok_result
fx.stopped_result = stopped_result
fx.failed_result = failed_result
fx.busy_wait = busy_wait
fx.sched = Sched

return fx
