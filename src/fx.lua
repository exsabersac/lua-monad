-- fx.lua — 「同步写法 / 异步效果」层（建在 Cont + Coro 之上）
--
-- 分层（详见 docs/fx分层.md）：
--   Core（推荐心智）：wait / wait_event / wait_until, stop/abort/fail,
--     fork+join(+handles), when_all/when_any, chan+send/recv/close,
--     with_timeout, supervise, register, run/start_session, with_resource, set_tracer
--   Sugar（可选）：lane*/proxy*/lanes, map_parallel/for_each_parallel, seq,
--     spawn/join_all 别名, connect/click 演示, wait_real, run_all/run_any/try
-- 重叠：when_all ≈ fork+join_handles ≈ lanes；lane≈命名 fork；proxy≈外部引用 lane/handle/flow
--
-- 公共 API 名全部保留；本文件只做薄包装与分区，不删导出。
--
-- 依赖：cont.lua、coro.lua、fx_sched.lua（及 fx_sched_*）、fx_registry.lua、fx_flow.lua
--
-- 标准 kind：wait, wait_event, wait_until, wait_real, chan_*, when_all/any,
--   fork, join, join_handles, lane*, proxy_*, with_timeout, supervise
-- 演示/遗留 mock：connect, click；自定义：fx.register

local Cont = require("cont")
local Coro = require("coro")
local Sched = require("fx_sched")
local Registry = require("fx_registry")
local Flow = require("fx_flow")

local fx = {}

------------------------------------------------------------
-- 内部：yield 形状复用（lane/proxy/join 等薄包装共用）
------------------------------------------------------------

local function yield_unit(req)
  return Coro.yield(req) >> function(v)
    return Cont.unit(v)
  end
end

-- join 族：kind + 字段 + 可选 cancel_siblings
local function yield_join(kind, fields, opts)
  opts = opts or {}
  local req = { kind = kind }
  for k, v in pairs(fields) do
    req[k] = v
  end
  if opts.cancel_siblings then
    req.cancel_siblings = true
  end
  return yield_unit(req)
end

-- stop/abort 族：lane_* / proxy_* 同形
local function yield_control(kind, fields, reason)
  local req = { kind = kind }
  for k, v in pairs(fields) do
    req[k] = v
  end
  if reason ~= nil then
    req.reason = reason
  end
  return yield_unit(req)
end

------------------------------------------------------------
-- ========== CORE（推荐心智）==========
------------------------------------------------------------

------------------------------------------------------------
-- Core · 等待
------------------------------------------------------------

-- wait : number → Cont Answer boolean
function fx.wait(seconds)
  seconds = seconds or 0
  return yield_unit({ kind = "wait", seconds = seconds })
end

-- wait_event : name → filter? → Cont Answer payload
function fx.wait_event(name, filter)
  assert(name ~= nil, "fx.wait_event: name required")
  local req = { kind = "wait_event", name = name }
  if filter ~= nil then
    req.filter = filter
  end
  return yield_unit(req)
end

-- wait_until : pred → opts? → Cont Answer result
-- 需 schedule_poll（FrameScheduler / GameSim）；无 scheduler 时演示回退 busy 轮询
function fx.wait_until(pred, opts)
  assert(type(pred) == "function", "fx.wait_until: pred must be function")
  opts = opts or {}
  local req = { kind = "wait_until", pred = pred }
  if opts.interval ~= nil then
    assert(type(opts.interval) == "number" and opts.interval >= 0,
      "fx.wait_until: opts.interval must be >= 0")
    req.interval = opts.interval
  end
  return yield_unit(req)
end

------------------------------------------------------------
-- Core · 终态
------------------------------------------------------------

-- stop：合作式 Stopped；abort：异常 Aborted（join/when_all 不算成功）；fail：Failed
function fx.stop(reason)
  return Coro.stop(reason)
end

function fx.abort(reason)
  return Coro.abort(reason)
end

function fx.fail(err)
  return Coro.fail(err)
end

------------------------------------------------------------
-- Core · 有界 channel
------------------------------------------------------------

fx.CHAN_DEFAULT_CAPACITY = 1

function fx.chan(capacity)
  if capacity == nil then
    capacity = fx.CHAN_DEFAULT_CAPACITY
  end
  assert(type(capacity) == "number" and capacity >= 0 and capacity == math.floor(capacity),
    "fx.chan: capacity must be a non-negative integer")
  return {
    _tag = "fx.chan",
    capacity = capacity,
    buf = {},
    closed = false,
    send_q = {},
    recv_q = {},
  }
end

local function assert_chan(ch, who)
  assert(type(ch) == "table" and ch._tag == "fx.chan",
    who .. ": expected fx.chan(...) channel")
end

function fx.send(ch, value)
  assert_chan(ch, "fx.send")
  return yield_unit({ kind = "chan_send", chan = ch, value = value })
end

function fx.recv(ch)
  assert_chan(ch, "fx.recv")
  return yield_unit({ kind = "chan_recv", chan = ch })
end

function fx.close(ch)
  assert_chan(ch, "fx.close")
  return yield_unit({ kind = "chan_close", chan = ch })
end

function fx.is_closed(ch)
  assert_chan(ch, "fx.is_closed")
  return not not ch.closed
end

------------------------------------------------------------
-- Core · 并行组合（when_*）与 Fork/Join
------------------------------------------------------------

function fx.when_all(mas)
  assert(type(mas) == "table", "fx.when_all: expected array of Cont Answer")
  return yield_unit({ kind = "when_all", tasks = mas })
end

function fx.when_any(mas)
  assert(type(mas) == "table", "fx.when_any: expected array of Cont Answer")
  return yield_unit({ kind = "when_any", tasks = mas })
end

function fx.fork(ma)
  assert(ma ~= nil, "fx.fork: expected Cont Answer")
  return yield_unit({ kind = "fork", task = ma })
end

function fx.join(handle, opts)
  assert(type(handle) == "table" and handle.id ~= nil,
    "fx.join: expected handle {id=...}")
  return yield_join("join", { handle = handle }, opts)
end

function fx.join_handles(handles, opts)
  assert(type(handles) == "table", "fx.join_handles: expected array of handles")
  return yield_join("join_handles", { handles = handles }, opts)
end

------------------------------------------------------------
-- Core · 超时 / 监督
------------------------------------------------------------

function fx.with_timeout(ma, seconds, opts)
  assert(ma ~= nil, "fx.with_timeout: expected Cont Answer")
  assert(type(seconds) == "number" and seconds >= 0,
    "fx.with_timeout: seconds must be >= 0")
  opts = opts or {}
  local on_timeout = opts.on_timeout
  if on_timeout == nil then
    on_timeout = "timeout"
  end
  return yield_unit({
    kind = "with_timeout",
    task = ma,
    seconds = seconds,
    on_timeout = on_timeout,
  })
end

function fx.supervise(ma, opts)
  assert(ma ~= nil, "fx.supervise: expected Cont Answer")
  opts = opts or {}
  local max_restarts = opts.max_restarts
  if max_restarts == nil then
    max_restarts = 3
  end
  assert(type(max_restarts) == "number" and max_restarts >= 0 and max_restarts == math.floor(max_restarts),
    "fx.supervise: opts.max_restarts must be a non-negative integer")
  local backoff = opts.backoff
  if backoff == nil then
    backoff = 0
  end
  assert(type(backoff) == "number" and backoff >= 0,
    "fx.supervise: opts.backoff must be >= 0")
  if opts.restart_if ~= nil then
    assert(type(opts.restart_if) == "function", "fx.supervise: opts.restart_if must be function")
  end
  if opts.on_fail ~= nil then
    assert(type(opts.on_fail) == "function", "fx.supervise: opts.on_fail must be function")
  end
  local req = {
    kind = "supervise",
    task = ma,
    max_restarts = max_restarts,
    backoff = backoff,
  }
  if opts.restart_if ~= nil then
    req.restart_if = opts.restart_if
  end
  if opts.on_fail ~= nil then
    req.on_fail = opts.on_fail
  end
  if opts.restart_on_stop then
    req.restart_on_stop = true
  end
  return yield_unit(req)
end

------------------------------------------------------------
-- Core · 注册表 / 资源 / 追踪 / 实体 / 运行
------------------------------------------------------------

function fx.register(kind, handler, opts)
  return Registry.register(kind, handler, opts)
end

function fx.unregister(kind)
  return Registry.unregister(kind)
end

fx.registry = Registry

function fx.with_resource(acquire, use, release)
  return Cont.bracket(acquire, use, release)
end

fx.bracket = fx.with_resource

function fx.set_tracer(fn)
  return Sched.set_tracer(fn)
end

function fx.get_tracer()
  return Sched.get_tracer()
end

function fx.bind_entity(flow, entity, opts)
  return Flow.bind_entity(flow, entity, opts)
end

fx.flow = Flow
fx.sched = Sched -- start_session / run_session 等见 fx_sched

local function busy_wait(seconds)
  Sched.busy_wait(seconds)
end

-- 默认 mock：wait + 演示 connect/click；并行 kind 由 session 处理
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
  stop = function(req)
    return { kind = "stop", reason = req.reason }
  end,
}

local function merge_handlers(overrides)
  return Registry.merge_handlers(default_handlers, overrides)
end

local function ok_result(v)
  return { ok = true, value = v }
end

local function stopped_result(reason)
  return { ok = false, stopped = true, reason = reason }
end

local function failed_result(err)
  return { ok = false, failed = true, error = err }
end

local function sched_opts_from(opts, h)
  opts = opts or {}
  return {
    cancel = opts.cancel,
    verbose_wait = opts.verbose_wait,
    scheduler = opts.scheduler or opts.game,
    game = opts.game,
    listen = opts.listen,
    unlisten = opts.unlisten,
    async_kinds = opts.async_kinds or (h and h.__async_kinds),
    trace = opts.trace,
    allow_real_time = opts.allow_real_time,
  }
end

function fx.run_parallel(tasks, handlers, opts)
  opts = opts or {}
  local mode = opts.mode or "all"
  local h = merge_handlers(handlers)
  return Sched.run_parallel(tasks, h, sched_opts_from(opts, h), mode)
end

function fx.run(ma, handlers, opts)
  opts = opts or {}
  local h = merge_handlers(handlers)
  if type(handlers) == "table" and type(handlers.__async_kinds) == "table" then
    h.__async_kinds = handlers.__async_kinds
  end
  return Sched.run_session(ma, h, sched_opts_from(opts, h))
end

fx.default_handlers = default_handlers
fx.ok_result = ok_result
fx.stopped_result = stopped_result
fx.failed_result = failed_result
fx.busy_wait = busy_wait

------------------------------------------------------------
-- ========== SUGAR（可选；导出保留）==========
------------------------------------------------------------

------------------------------------------------------------
-- Sugar · 墙钟等待 / 演示效果
------------------------------------------------------------

-- wait_real：墙钟（opt-in）；默认游戏逻辑请用 wait + 游戏时间 scheduler
function fx.wait_real(seconds)
  seconds = seconds or 0
  return yield_unit({ kind = "wait_real", seconds = seconds })
end

function fx.connect(host, opts)
  local req = { kind = "connect", host = host }
  if opts ~= nil then
    req.opts = opts
  end
  return yield_unit(req)
end

function fx.click(target)
  return yield_unit({ kind = "click", target = target })
end

------------------------------------------------------------
-- Sugar · 顺序 / 别名
------------------------------------------------------------

function fx.seq(mas)
  assert(type(mas) == "table", "fx.seq: expected array of Cont Answer")
  local n = #mas
  if n == 0 then
    return Cont.unit(nil)
  end
  local m = mas[1]
  for i = 2, n do
    m = Cont.chain(m, mas[i])
  end
  return m
end

fx.throw = fx.fail
fx.spawn = fx.fork
fx.join_all = fx.when_all
fx.join_any = fx.when_any

------------------------------------------------------------
-- Sugar · 命名 lane（≈ tabMachine c:start("t1")；≈ 命名 fork）
------------------------------------------------------------

function fx.lane(name, ma)
  assert(type(name) == "string" and name ~= "",
    "fx.lane: name must be non-empty string")
  assert(ma ~= nil, "fx.lane: expected Cont Answer")
  return yield_unit({ kind = "lane", name = name, task = ma })
end

function fx.lane_join(name, opts)
  assert(type(name) == "string" and name ~= "",
    "fx.lane_join: name must be non-empty string")
  return yield_join("lane_join", { name = name }, opts)
end

function fx.lane_stop(name, reason)
  assert(type(name) == "string" and name ~= "",
    "fx.lane_stop: name must be non-empty string")
  return yield_control("lane_stop", { name = name }, reason)
end

function fx.lane_abort(name, reason)
  assert(type(name) == "string" and name ~= "",
    "fx.lane_abort: name must be non-empty string")
  return yield_control("lane_abort", { name = name }, reason)
end

-- lanes：按名启动再 join_handles（≈ when_all 的命名版）
function fx.lanes(map)
  assert(type(map) == "table", "fx.lanes: expected name→Cont map")
  local names = {}
  for name, ma in pairs(map) do
    assert(type(name) == "string" and name ~= "",
      "fx.lanes: keys must be non-empty strings")
    assert(ma ~= nil, "fx.lanes: Cont required for lane " .. tostring(name))
    names[#names + 1] = name
  end
  table.sort(names)
  if #names == 0 then
    return Cont.unit({})
  end
  local function start_at(i, entries)
    if i > #names then
      local handles = {}
      for j = 1, #entries do
        handles[j] = entries[j].handle
      end
      return fx.join_handles(handles) >> function(vals)
        local out = {}
        for j = 1, #entries do
          out[entries[j].name] = vals[j]
        end
        return Cont.unit(out)
      end
    end
    local name = names[i]
    return fx.lane(name, map[name]) >> function(h)
      entries[#entries + 1] = { name = name, handle = h }
      return start_at(i + 1, entries)
    end
  end
  return start_at(1, {})
end

------------------------------------------------------------
-- Sugar · 轻量 proxy（≈ tabProxy；外部引用 lane/handle/flow）
------------------------------------------------------------

local function make_proxy(fields, opts)
  opts = opts or {}
  local p = {
    _is_proxy = true,
    stop_host_when_stop = not not opts.stop_host_when_stop,
  }
  for k, v in pairs(fields) do
    p[k] = v
  end
  return p
end

function fx.proxy(name_or_handle, opts)
  assert(name_or_handle ~= nil, "fx.proxy: name_or_handle required")
  if type(name_or_handle) == "string" then
    assert(name_or_handle ~= "", "fx.proxy: name must be non-empty string")
    return make_proxy({ name = name_or_handle }, opts)
  end
  assert(type(name_or_handle) == "table",
    "fx.proxy: expected string name, handle {id=…}, or flow")
  if name_or_handle._is_flow then
    return make_proxy({ flow = name_or_handle }, opts)
  end
  if name_or_handle._is_proxy then
    if opts ~= nil then
      return make_proxy({
        name = name_or_handle.name,
        id = name_or_handle.id,
        flow = name_or_handle.flow,
      }, opts)
    end
    return name_or_handle
  end
  assert(name_or_handle.id ~= nil, "fx.proxy: handle must have .id")
  local fields = { id = name_or_handle.id }
  if type(name_or_handle.name) == "string" then
    fields.name = name_or_handle.name
  end
  return make_proxy(fields, opts)
end

function fx.proxy_join(proxy, opts)
  assert(type(proxy) == "table" and proxy._is_proxy,
    "fx.proxy_join: expected proxy from fx.proxy / flow:proxy")
  return yield_join("proxy_join", { proxy = proxy }, opts)
end

function fx.proxy_stop(proxy, reason)
  assert(type(proxy) == "table" and proxy._is_proxy,
    "fx.proxy_stop: expected proxy")
  return yield_control("proxy_stop", { proxy = proxy }, reason)
end

function fx.proxy_abort(proxy, reason)
  assert(type(proxy) == "table" and proxy._is_proxy,
    "fx.proxy_abort: expected proxy")
  return yield_control("proxy_abort", { proxy = proxy }, reason)
end

------------------------------------------------------------
-- Sugar · 有限并发池
------------------------------------------------------------

function fx.map_parallel(items, worker, opts)
  assert(type(items) == "table", "fx.map_parallel: items must be an array")
  assert(type(worker) == "function", "fx.map_parallel: worker must be function(item, index) → Cont Answer")
  opts = opts or {}
  local concurrency = opts.concurrency
  if concurrency == nil then
    concurrency = 4
  end
  assert(type(concurrency) == "number" and concurrency >= 1,
    "fx.map_parallel: opts.concurrency must be >= 1")

  local n = #items
  if n == 0 then
    return Cont.unit({})
  end

  local function start_one(i)
    return fx.fork(worker(items[i], i)) >> function(h)
      return Cont.unit({ handle = h, index = i })
    end
  end

  -- 滑动窗口：原地 queue/results（逐步顺序执行，无并发改同一表）
  local function step(next_i, queue, results)
    local function fill(ni)
      if #queue >= concurrency or ni > n then
        return Cont.unit(ni)
      end
      return start_one(ni) >> function(entry)
        queue[#queue + 1] = entry
        return fill(ni + 1)
      end
    end

    return fill(next_i) >> function(ni)
      if #queue == 0 then
        return Cont.unit(results)
      end
      local head = table.remove(queue, 1)
      return fx.join(head.handle) >> function(v)
        results[head.index] = v
        return step(ni, queue, results)
      end
    end
  end

  return step(1, {}, {})
end

function fx.for_each_parallel(items, worker, opts)
  return fx.map_parallel(items, worker, opts) >> function(_vals)
    return Cont.unit(true)
  end
end

------------------------------------------------------------
-- Sugar · 顶层别名 / try
------------------------------------------------------------

local function run_parallel_mode(mode, tasks, handlers, opts)
  opts = opts or {}
  local o = {}
  for k, v in pairs(opts) do
    o[k] = v
  end
  o.mode = mode
  return fx.run_parallel(tasks, handlers, o)
end

function fx.run_all(tasks, handlers, opts)
  return run_parallel_mode("all", tasks, handlers, opts)
end

function fx.run_any(tasks, handlers, opts)
  return run_parallel_mode("any", tasks, handlers, opts)
end

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

return fx
