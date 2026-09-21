-- fx.lua — 教学用「同步写法 / 异步效果」层（建在 Cont + Coro 之上）
--
-- 核心思想：
--   1. 业务代码用 Cont.withEnv 写成看起来同步的步骤管道（open → wait → click → …）。
--   2. 真正的 wait / 网络 / 点击等「效果」并不在业务里执行，而是 Coro.yield 一条
--      Yielded 请求（{ kind=..., ... }）；外部解释器（fx.run 的 handlers）兑现后再 resume。
--   3. fx.stop / fx.abort / fx.fail 走 Coro Answer 终态（Stopped / Aborted / Failed），中止管道而不再调 handler。
--      stop=合作式停止；abort=异常中止（fork 子 abort 时 join/when_all 传播 Aborted，不算成功值）。
--      opts.cancel_siblings：join 成功后取消兄弟；若兄弟正在 abort/stop，waiter 仍以先到终态为准。
--   3b. fx.seq(mas)：左到右 >> 串联 Cont，返回最后值（≈ tabMachine `..` / g_t.seq）；空 → unit(nil)。
--   4. fx.when_all / fx.when_any 把并行组合编成 yield；由调度器时间轮并发驱动（对齐 C# WhenAll/WhenAny）。
--   5. fx.fork / fx.join / fx.join_handles：非结构化并发（先 fork，中间可做别的事，再 join）。
--   5b. fx.lane / lane_join / lane_stop / lane_abort / lanes：命名子流（≈ tabMachine c:start("t1")）；
--       session.lanes 名表 + 复用 fork/join nursery。
--   5c. fx.proxy / proxy_join / proxy_stop / proxy_abort（+ flow:proxy）：轻量 tabProxy 对照；
--       外部 wait/stop 句柄，不拥有 Cont；复用 fork/join joiners；可选 stop_host_when_stop。
--   6. fx.map_parallel：有限并发池（滑动窗口 fork/join，结果按输入顺序）。
--   7. fx.with_timeout：与 wait(deadline) 竞速；超时 → Failed("timeout")（可自定义）。
--      截止时间向下传播到 fork 子任务；子可再用更紧的 with_timeout。
--   7b. fx.supervise：子 Failed（可选 Stopped）时按 max_restarts / backoff 重启；
--       cancel supervise 取消当前子且不再重启；backoff 走游戏时间 scheduler。
--   8. 取消传播树：session cancel 停止未完成子任务；join 可选 cancel_siblings。
--      父 deadline 触发时递归 Stopped 未完成后代（finally 经 force_stop）。
--   9. 这不是真实网络/UI；默认 handlers 只是 mock，便于演示与测试。
--  10. opts.scheduler / opts.game：外部游戏时间后端；wait 走 schedule，不 busy_wait。
--  11. fx.wait_event：由 GameSim.emit / listen 兑现。
--  11b. fx.wait_until(pred, opts?)：每 tick/interval poll 谓词；需 FrameScheduler / GameSim.schedule_poll。
--  11c. fx.wait_real(seconds)：墙钟等待（opt-in）；kind=wait_real；默认 Failed；见 opts.allow_real_time / schedule_real。
--  11d. fx.chan / send / recv / close：有界 channel（mailbox）；yield chan_send|chan_recv|chan_close。
--  12. fx.register / unregister：全局效果注册表（见 fx_registry）；未知 kind → Failed。
--  13. fx.with_resource / Cont.bracket：资源获取-使用-释放（Done/Stopped/Failed 皆 release）。
--  14. opts.trace / fx.set_tracer：轻量 flow 追踪（默认关闭）。
--  15. fx.bind_entity / fx_flow：实体销毁绑定 cancel。
--
-- 重要区分：
--   Cont 上的 Coro.yield ≠ Lua 原生 coroutine.yield。
--   Coro 用 Cont 编码答案类型 Done | Yielded | Stopped | Aborted | Failed；业务 API 请走本模块 / Coro，
--   不要当原生协程 perform/runDo 用（本库主线已放弃 native perform/runDo）。
--
-- 依赖：cont.lua、coro.lua、fx_sched.lua、fx_registry.lua、fx_flow.lua
--
-- 标准 kind 一览（详见 fx_registry.STANDARD_KINDS）：
--   内建：wait, wait_event, wait_until, wait_real, chan_send, chan_recv, chan_close,
--         when_all, when_any, fork, join, join_handles,
--         lane, lane_join, lane_stop, lane_abort,
--         proxy_join, proxy_stop, proxy_abort, with_timeout, supervise
--   演示：anim（需 register）；遗留 mock：connect, click

local Cont = require("cont")
local Coro = require("coro")
local Sched = require("fx_sched")
local Registry = require("fx_registry")
local Flow = require("fx_flow")

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

-- wait_event : name → filter? → Cont Answer payload
-- 挂起 { kind="wait_event", name, filter? }；GameSim.emit 匹配后 resume
function fx.wait_event(name, filter)
  assert(name ~= nil, "fx.wait_event: name required")
  local req = { kind = "wait_event", name = name }
  if filter ~= nil then
    req.filter = filter
  end
  return Coro.yield(req) >> function(payload)
    return Cont.unit(payload)
  end
end

-- wait_until : pred → opts? → Cont Answer result
-- 每 tick（或 opts.interval 秒）调用 pred()；返回真值时 resume 该值。
-- 需 session opts.scheduler 提供 schedule_poll（FrameScheduler / GameSim）；
-- 无 scheduler 时演示回退：busy_wait 忙轮询（勿用于工程路径）。
-- Yield: { kind="wait_until", pred=fn, interval?=number }
function fx.wait_until(pred, opts)
  assert(type(pred) == "function", "fx.wait_until: pred must be function")
  opts = opts or {}
  local req = { kind = "wait_until", pred = pred }
  if opts.interval ~= nil then
    assert(type(opts.interval) == "number" and opts.interval >= 0,
      "fx.wait_until: opts.interval must be >= 0")
    req.interval = opts.interval
  end
  return Coro.yield(req) >> function(result)
    return Cont.unit(result)
  end
end

-- wait_real : number → Cont Answer boolean
-- 墙钟 / realtime 等待（秒）。**默认不用于游戏逻辑**；仅网络/SDK 等少数场景。
-- Yield: { kind="wait_real", seconds=... }
-- Session 兑现规则（见 fx_sched）：
--   1) opts.scheduler.schedule_real(delay, cb) 存在 → 走宿主墙钟调度（推荐 Unity WaitForSecondsRealtime）
--   2) 否则若 opts.allow_real_time → busy_wait / os.clock（演示/单测）
--   3) 否则 → Failed{ tag="wait_real_unsupported", message="wait_real unsupported" }
-- MockUnityHost / VirtualClock 默认无 schedule_real，且勿开 allow_real_time。
function fx.wait_real(seconds)
  seconds = seconds or 0
  return Coro.yield({ kind = "wait_real", seconds = seconds }) >> function(_resume)
    return Cont.unit(true)
  end
end

------------------------------------------------------------
-- 有界 channel / mailbox（多 flow 协作）
------------------------------------------------------------

-- 默认容量 1：贴近 mailbox / notify（可暂存一条）；缓冲队列请显式传更大 n。
-- 容量 0：会合（rendezvous）——send 必须等到 recv。
fx.CHAN_DEFAULT_CAPACITY = 1

-- chan : n? → Channel
-- Channel 是普通表（可跨 session / GameSim flow 共享）；不经 yield。
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

-- send : Channel → value → Cont Answer true
-- 缓冲未满则入队；满则挂起直至有 recv 腾出空间；已关闭 → Failed{tag="chan_closed"}。
-- Yield: { kind="chan_send", chan=ch, value=v }
function fx.send(ch, value)
  assert_chan(ch, "fx.send")
  return Coro.yield({ kind = "chan_send", chan = ch, value = value }) >> function(_ok)
    return Cont.unit(true)
  end
end

-- recv : Channel → Cont Answer value
-- 缓冲有值则取出；空则挂起直至 send；已关闭且空 → Failed{tag="chan_closed"}。
-- Yield: { kind="chan_recv", chan=ch }
function fx.recv(ch)
  assert_chan(ch, "fx.recv")
  return Coro.yield({ kind = "chan_recv", chan = ch }) >> function(value)
    return Cont.unit(value)
  end
end

-- close : Channel → Cont Answer true
-- 标记关闭：唤醒/失败等待中的 send；缓冲排空后 recv 得 chan_closed。
-- Yield: { kind="chan_close", chan=ch }
function fx.close(ch)
  assert_chan(ch, "fx.close")
  return Coro.yield({ kind = "chan_close", chan = ch }) >> function(_ok)
    return Cont.unit(true)
  end
end

-- is_closed : Channel → boolean（同步，不挂起）
function fx.is_closed(ch)
  assert_chan(ch, "fx.is_closed")
  return not not ch.closed
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
-- 合作式中止：返回 Coro.Stopped，不调用后续续延 / handler。
-- 父 join / join_handles / when_all 得到 Stopped（非成功值）；见 docs/tabMachine对照.md。
function fx.stop(reason)
  return Coro.stop(reason)
end

-- abort : reason? → Cont Answer b
-- 异常中止：返回 Coro.Aborted。fork 子任务 abort 时，join/when_all **不算成功**，
-- 向 waiter 传播 Aborted（与 stop 一样非成功，但 tag 可区分；cancel 仍用 Stopped）。
function fx.abort(reason)
  return Coro.abort(reason)
end

-- fail : err → Cont Answer b
-- 管道级失败：返回 Coro.Failed（亦可写作 fx.throw 别名）
function fx.fail(err)
  return Coro.fail(err)
end

fx.throw = fx.fail -- 别名：与 Cont.throw 对照时可用 fx.throw 表示 Coro 层失败

------------------------------------------------------------
-- 顺序组合（≈ tabMachine `..` / g_t.seq）
------------------------------------------------------------

-- seq : { Cont Answer a, ... } → Cont Answer last
-- 左到右串联（忽略中间值，保留最后 Cont 的值）；空数组 → Cont.unit(nil)
-- 使用 Cont.chain（≡ ma .. mb），避免每步 `>> function(_) return next end` 的额外闭包
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
-- Fork / Join（非结构化并发；与 when_all 互补）
------------------------------------------------------------

-- fork : Cont Answer a → Cont Answer Handle
-- 启动子 Cont 并发；父任务立刻拿到不透明 handle（{ id=number }）
-- Yield: { kind="fork", task=ma }
function fx.fork(ma)
  assert(ma ~= nil, "fx.fork: expected Cont Answer")
  return Coro.yield({ kind = "fork", task = ma }) >> function(handle)
    return Cont.unit(handle)
  end
end

fx.spawn = fx.fork -- 别名：≈ Task.Run / 启动子任务

-- join : Handle → opts? → Cont Answer a
-- 等到该 fork 子任务 Done，resume 其值；Failed/Stopped/Aborted 向父传播（abort≠成功）
-- opts.cancel_siblings=true：join **成功**后，停止同一 fork 父任务下其它未完成兄弟
--   （兄弟若先 abort/stop，本 join 会先失败，不会走到 cancel_siblings）
-- Yield: { kind="join", handle=h, cancel_siblings?=bool }
function fx.join(handle, opts)
  assert(type(handle) == "table" and handle.id ~= nil,
    "fx.join: expected handle {id=...}")
  opts = opts or {}
  local req = { kind = "join", handle = handle }
  if opts.cancel_siblings then
    req.cancel_siblings = true
  end
  return Coro.yield(req) >> function(value)
    return Cont.unit(value)
  end
end

-- join_handles : { Handle, ... } → opts? → Cont Answer { a, ... }
-- 按 handle 列表顺序收集结果（≈ when_all 的 values 顺序）
-- opts.cancel_siblings=true：全部成功 join 后，取消同父下未纳入本集合的兄弟
-- Yield: { kind="join_handles", handles=hs, cancel_siblings?=bool }
function fx.join_handles(handles, opts)
  assert(type(handles) == "table", "fx.join_handles: expected array of handles")
  opts = opts or {}
  local req = { kind = "join_handles", handles = handles }
  if opts.cancel_siblings then
    req.cancel_siblings = true
  end
  return Coro.yield(req) >> function(values)
    return Cont.unit(values)
  end
end

------------------------------------------------------------
-- 命名 lane（轻量 tabMachine 多行：c:start("t1") 对照）
-- 复用 fork/join nursery；session.lanes[name] = task_id
------------------------------------------------------------

-- lane : name → Cont Answer a → Cont Answer Handle
-- 启动 ma 为命名子 lane；立刻 resume handle { id, name }
-- 同名仍在跑 → Failed { tag="lane_busy", name }
-- Yield: { kind="lane", name, task=ma }
function fx.lane(name, ma)
  assert(type(name) == "string" and name ~= "",
    "fx.lane: name must be non-empty string")
  assert(ma ~= nil, "fx.lane: expected Cont Answer")
  return Coro.yield({ kind = "lane", name = name, task = ma }) >> function(handle)
    return Cont.unit(handle)
  end
end

-- lane_join : name → opts? → Cont Answer a
-- 等到该名 lane Done；Failed/Stopped/Aborted 向父传播（同 fx.join）
-- 未知名 → Failed { tag="lane_unknown", name }
-- Yield: { kind="lane_join", name, cancel_siblings?=bool }
function fx.lane_join(name, opts)
  assert(type(name) == "string" and name ~= "",
    "fx.lane_join: name must be non-empty string")
  opts = opts or {}
  local req = { kind = "lane_join", name = name }
  if opts.cancel_siblings then
    req.cancel_siblings = true
  end
  return Coro.yield(req) >> function(value)
    return Cont.unit(value)
  end
end

-- lane_stop : name → reason? → Cont Answer bool
-- 合作式停止命名 lane（Stopped）；resume true=曾在跑，false=无名/已终态
-- Yield: { kind="lane_stop", name, reason? }
function fx.lane_stop(name, reason)
  assert(type(name) == "string" and name ~= "",
    "fx.lane_stop: name must be non-empty string")
  local req = { kind = "lane_stop", name = name }
  if reason ~= nil then
    req.reason = reason
  end
  return Coro.yield(req) >> function(ok)
    return Cont.unit(ok)
  end
end

-- lane_abort : name → reason? → Cont Answer bool
-- 异常中止命名 lane（Aborted，join 不算成功）；resume true/false 同 lane_stop
-- Yield: { kind="lane_abort", name, reason? }
function fx.lane_abort(name, reason)
  assert(type(name) == "string" and name ~= "",
    "fx.lane_abort: name must be non-empty string")
  local req = { kind = "lane_abort", name = name }
  if reason ~= nil then
    req.reason = reason
  end
  return Coro.yield(req) >> function(ok)
    return Cont.unit(ok)
  end
end

-- lanes : { name = Cont Answer a, ... } → Cont Answer { name = a, ... }
-- 按名排序后依次 lane 启动，再 join_handles 汇合（并发跑，结果按名字典）
-- 空 map → unit({})
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
-- 轻量 proxy（≈ tabMachine tabProxy：外部 wait/stop，不拥有 Cont）
-- 复用 fork/join joiners；目标可为 lane 名、fork/lane handle、或 flow
------------------------------------------------------------

local function proxy_opts(opts)
  opts = opts or {}
  return not not opts.stop_host_when_stop
end

-- 构造 proxy 句柄（纯表，非 Cont）
local function make_proxy(fields, opts)
  local p = {
    _is_proxy = true,
    stop_host_when_stop = proxy_opts(opts),
  }
  for k, v in pairs(fields) do
    p[k] = v
  end
  return p
end

-- proxy : name|handle|flow → opts? → Proxy
--   string → 命名 lane；{id=…} → fork/lane 任务；flow → 整段 session
-- opts.stop_host_when_stop：proxy_join 等待方被取消时，反向停止目标（≈ tabProxy）
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
    -- 已是 proxy：可选覆盖 stop_host_when_stop
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

-- proxy_join : Proxy → opts? → Cont Answer a
-- 等到目标 Done；Failed/Stopped/Aborted 向父传播（同 join）
-- 未知目标 → Failed { tag="proxy_unknown" }
-- Yield: { kind="proxy_join", proxy, cancel_siblings?=bool }
function fx.proxy_join(proxy, opts)
  assert(type(proxy) == "table" and proxy._is_proxy,
    "fx.proxy_join: expected proxy from fx.proxy / flow:proxy")
  opts = opts or {}
  local req = { kind = "proxy_join", proxy = proxy }
  if opts.cancel_siblings then
    req.cancel_siblings = true
  end
  return Coro.yield(req) >> function(value)
    return Cont.unit(value)
  end
end

-- proxy_stop : Proxy → reason? → Cont Answer bool
-- 合作式停止目标（Stopped）；resume true=曾在跑，false=未知/已终态
-- Yield: { kind="proxy_stop", proxy, reason? }
function fx.proxy_stop(proxy, reason)
  assert(type(proxy) == "table" and proxy._is_proxy,
    "fx.proxy_stop: expected proxy")
  local req = { kind = "proxy_stop", proxy = proxy }
  if reason ~= nil then
    req.reason = reason
  end
  return Coro.yield(req) >> function(ok)
    return Cont.unit(ok)
  end
end

-- proxy_abort : Proxy → reason? → Cont Answer bool
-- 异常中止目标（Aborted）；resume true/false 同 proxy_stop
-- Yield: { kind="proxy_abort", proxy, reason? }
function fx.proxy_abort(proxy, reason)
  assert(type(proxy) == "table" and proxy._is_proxy,
    "fx.proxy_abort: expected proxy")
  local req = { kind = "proxy_abort", proxy = proxy }
  if reason ~= nil then
    req.reason = reason
  end
  return Coro.yield(req) >> function(ok)
    return Cont.unit(ok)
  end
end

------------------------------------------------------------
-- 有限并发池（map_parallel）
------------------------------------------------------------

-- map_parallel : {item,...} → (item,index → Cont Answer a) → opts? → Cont Answer {a,...}
-- opts.concurrency（默认 4，须 >= 1）：同时在飞的 worker 数上限
-- 结果数组与 items 下标对齐（同 when_all）
-- 实现：滑动窗口 — 先 fork 最多 N 个，按启动顺序 join；每完成一个再启动下一个
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

  -- queue: { {handle=h, index=i}, ... } 按启动顺序；results[i] = worker 返回值
  local function start_one(i)
    return fx.fork(worker(items[i], i)) >> function(h)
      return Cont.unit({ handle = h, index = i })
    end
  end

  -- 填满窗口后，join 队首；再尝试 fork 下一个，递归直至队列空
  local function step(next_i, queue, results)
    -- 尽量填满至 concurrency
    local function fill(ni, q)
      if #q >= concurrency or ni > n then
        return Cont.unit({ ni = ni, q = q })
      end
      return start_one(ni) >> function(entry)
        local q2 = {}
        for j = 1, #q do
          q2[j] = q[j]
        end
        q2[#q2 + 1] = entry
        return fill(ni + 1, q2)
      end
    end

    return fill(next_i, queue) >> function(st)
      local ni, q = st.ni, st.q
      if #q == 0 then
        return Cont.unit(results)
      end
      local head = q[1]
      local rest = {}
      for j = 2, #q do
        rest[#rest + 1] = q[j]
      end
      return fx.join(head.handle) >> function(v)
        local results2 = {}
        for j = 1, n do
          results2[j] = results[j]
        end
        results2[head.index] = v
        return step(ni, rest, results2)
      end
    end
  end

  return step(1, {}, {})
end

-- for_each_parallel：同 map_parallel，但丢弃各 worker 返回值，最终 Cont.unit(true)
function fx.for_each_parallel(items, worker, opts)
  return fx.map_parallel(items, worker, opts) >> function(_vals)
    return Cont.unit(true)
  end
end

------------------------------------------------------------
-- 超时竞速（with_timeout）
------------------------------------------------------------

-- with_timeout : Cont Answer a → seconds → opts? → Cont Answer a
-- 与 fx.wait(seconds) 竞速：ma 先 Done → 返回其值；超时 → Failed
-- 默认错误为字符串 "timeout"；opts.on_timeout 可换成自定义 reason（仍走 Failed）
-- 截止时间写入 body.deadline_abs，fork 子任务继承剩余 deadline；超时取消时递归 Stopped 后代
-- 若父已有更紧 deadline（session opts 或外层 with_timeout），取 min
-- 与 Cont.withEnv __Timeout__ 对照：属性是逐步（per-step）超时；本组合子包裹整段 Cont
-- Yield: { kind="with_timeout", task=ma, seconds=s, on_timeout=err }
function fx.with_timeout(ma, seconds, opts)
  assert(ma ~= nil, "fx.with_timeout: expected Cont Answer")
  assert(type(seconds) == "number" and seconds >= 0,
    "fx.with_timeout: seconds must be >= 0")
  opts = opts or {}
  local on_timeout = opts.on_timeout
  if on_timeout == nil then
    on_timeout = "timeout"
  end
  return Coro.yield({
    kind = "with_timeout",
    task = ma,
    seconds = seconds,
    on_timeout = on_timeout,
  }) >> function(value)
    return Cont.unit(value)
  end
end

------------------------------------------------------------
-- 监督式重启（supervise）
------------------------------------------------------------

-- supervise : Cont Answer a → opts? → Cont Answer a
-- 跑 child；Failed（可选 Stopped）时重启，直至成功或超过 max_restarts。
-- opts:
--   max_restarts（默认 3）：失败后最多再启次数（总尝试 = 1 + max_restarts）
--   backoff（默认 0）：重启前等待的游戏秒（有 scheduler 时走 schedule）
--   restart_if(err) → bool：是否允许本次重启（默认 true）
--   on_fail(err)：每次失败回调；若显式返回 false 则不再重启
--   restart_on_stop（默认 false）：Stopped 且 reason≠cancelled 时也重启
-- Aborted 默认不重启，直接传播。
-- Cancel / force_stop supervise：取消当前子（及 backoff timer），不再重启。
-- Yield: { kind="supervise", task=ma, max_restarts, backoff, ... }
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
  return Coro.yield(req) >> function(value)
    return Cont.unit(value)
  end
end

------------------------------------------------------------
-- 效果注册表（全局）
------------------------------------------------------------

--- register(kind, handler, opts?) — 见 fx_registry
function fx.register(kind, handler, opts)
  return Registry.register(kind, handler, opts)
end

function fx.unregister(kind)
  return Registry.unregister(kind)
end

fx.registry = Registry

------------------------------------------------------------
-- 资源 bracket（Done / Stopped / Failed 皆 release）
------------------------------------------------------------

--- with_resource(acquire, use, release) → Cont Answer
-- acquire() → resource | Cont resource
-- use(resource) → Cont Answer a
-- release(resource, outcome) → Cont|value；outcome={status,value?,error?,reason?}
-- 基于 Cont.finally：正常 Done、stop、fail、cancel 均会 release。
function fx.with_resource(acquire, use, release)
  return Cont.bracket(acquire, use, release)
end

-- 与 Cont.bracket / Haskell bracket 对照
fx.bracket = fx.with_resource

------------------------------------------------------------
-- 轻量追踪（默认关闭）
------------------------------------------------------------

--- set_tracer(fn|nil)；fn(ev) 收到 {type=..., ...}
function fx.set_tracer(fn)
  return Sched.set_tracer(fn)
end

function fx.get_tracer()
  return Sched.get_tracer()
end

------------------------------------------------------------
-- 实体绑定
------------------------------------------------------------

--- bind_entity(flow, entity, opts?) — 见 fx_flow
function fx.bind_entity(flow, entity, opts)
  return Flow.bind_entity(flow, entity, opts)
end

fx.flow = Flow

------------------------------------------------------------
-- 默认 mock handlers（可被 fx.run 的 handlers? 覆盖）
------------------------------------------------------------

local function busy_wait(seconds)
  Sched.busy_wait(seconds)
end

-- 默认处理器：打印日志 + mock 成功结果
-- kind="stop" 可选：若业务误用 Coro.yield{kind="stop"}，handlers 可识别；
-- 正常请用 fx.stop（直接 Stopped，不经过 handler）。
-- when_all / when_any / fork / join / lane* / proxy_* / with_timeout / supervise 由 session 调度器处理，不经本表。
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
  -- default → 全局注册表 → 调用方覆盖
  return Registry.merge_handlers(default_handlers, overrides)
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
    scheduler = opts.scheduler or opts.game,
    game = opts.game,
    listen = opts.listen,
    unlisten = opts.unlisten,
    async_kinds = opts.async_kinds or h.__async_kinds,
    trace = opts.trace,
    allow_real_time = opts.allow_real_time,
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

-- run : Cont Answer a → handlers? → opts? → result
-- 整段管道由 nursery session 驱动（与 when_all / fork·join 同一调度器）：
--   · 无 Yield 终态：同步快路径（跳过 nursery/pump；见 fx_sched.start_session）
--   · 单任务时 wait 仍走 handlers.wait（兼容瞬时 mock）
--   · 多任务 / fork 后 wait 走时间轮（墙钟 deadline）
--   · opts.cancel 协作取消父任务与未完成子任务
-- 始终返回结构化 result 表（破坏性变更：旧代码请用 result.value）。
function fx.run(ma, handlers, opts)
  opts = opts or {}
  local h = merge_handlers(handlers)
  -- 合并用户传入的异步 kind 标记
  if type(handlers) == "table" and type(handlers.__async_kinds) == "table" then
    h.__async_kinds = handlers.__async_kinds
  end
  return Sched.run_session(ma, h, {
    cancel = opts.cancel,
    verbose_wait = opts.verbose_wait,
    scheduler = opts.scheduler or opts.game,
    game = opts.game,
    listen = opts.listen,
    unlisten = opts.unlisten,
    async_kinds = opts.async_kinds or h.__async_kinds,
    trace = opts.trace,
    allow_real_time = opts.allow_real_time,
  })
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
