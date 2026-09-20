-- fx.lua — 教学用「同步写法 / 异步效果」层（建在 Cont + Coro 之上）
--
-- 核心思想：
--   1. 业务代码用 Cont.withEnv 写成看起来同步的步骤管道（open → wait → click → …）。
--   2. 真正的 wait / 网络 / 点击等「效果」并不在业务里执行，而是 Coro.yield 一条
--      Yielded 请求（{ kind=..., ... }）；外部解释器（fx.run 的 handlers）兑现后再 resume。
--   3. 这不是真实网络/UI；默认 handlers 只是 mock，便于演示与测试。
--
-- 重要区分：
--   Cont 上的 Coro.yield ≠ Lua 原生 coroutine.yield。
--   Coro 用 Cont 编码答案类型 Done | Yielded；业务 API 请走本模块 / Coro，不要当
--   原生协程 perform/runDo 用（本库主线已放弃 native perform/runDo）。
--
-- 依赖：cont.lua、coro.lua

local Cont = require("cont")
local Coro = require("coro")

local fx = {}

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

------------------------------------------------------------
-- 默认 mock handlers（可被 fx.run 的 handlers? 覆盖）
------------------------------------------------------------

local function busy_wait(seconds)
  if not seconds or seconds <= 0 then
    return
  end
  -- 优先尝试 luasocket 的 sleep；没有则用 os.clock 合作式忙等（演示用）
  local ok, socket = pcall(require, "socket")
  if ok and type(socket) == "table" and type(socket.sleep) == "function" then
    socket.sleep(seconds)
    return
  end
  local t0 = os.clock()
  while os.clock() - t0 < seconds do
    -- 合作式忙等：仅用于短演示，非生产调度
  end
end

-- 默认处理器：打印日志 + mock 成功结果
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
}

-- 合并用户 handlers 覆盖默认；未覆盖的 kind 仍走默认
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

-- run : Cont Answer a → handlers? → final_value
-- 用 Coro.run 驱动；按 yield 载荷的 kind 分派到 handlers（默认 mock 可覆盖）。
function fx.run(ma, handlers)
  local h = merge_handlers(handlers)
  return Coro.run(ma, function(req)
    assert(type(req) == "table" and req.kind ~= nil,
      "fx.run: expected yield payload table with .kind")
    local handler = h[req.kind]
    assert(handler, "fx.run: no handler for kind=" .. tostring(req.kind))
    return handler(req)
  end)
end

-- 暴露默认表便于测试/文档对照（请勿原地改；覆盖请传 fx.run 第二参）
fx.default_handlers = default_handlers

return fx
