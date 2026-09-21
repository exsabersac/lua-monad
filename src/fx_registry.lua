-- fx_registry.lua — 效果 kind 全局注册表（工程对接）
--
-- 业务只 Coro.yield{ kind=..., ... }；宿主 / 引擎通过 register 挂 handler。
-- Session（fx_sched）在解析「非内建」kind 时查本表（再经 handlers 合并覆盖）。
--
-- 内建由调度器直接处理（不必 register）：
--   wait, wait_event, wait_until, wait_real, chan_send, chan_recv, chan_close,
--   when_all, when_any, fork, join, join_handles, with_timeout, supervise
-- 演示 / 遗留 mock（默认 handlers 或示例 register）：
--   connect, click  — 教学 mock
--   anim           — GameSim / 示例自定义异步演示
--
-- 未知 kind：session 返回 Failed（含 effect_kind），不静默吞掉。

local M = {}

-- kind → { handler=fn, async=bool, meta?=table }
local _entries = {}

--- 标准 / 约定 kind 说明（文档用；不自动注册 handler）
M.STANDARD_KINDS = {
  wait = {
    role = "builtin",
    desc = "挂起 seconds；有 opts.scheduler 时走游戏时间 schedule，否则 busy_wait / 时间轮",
  },
  wait_event = {
    role = "builtin",
    desc = "挂起 name(+filter?)；由 scheduler.listen / GameSim.emit 或 handlers.wait_event 兑现",
  },
  wait_until = {
    role = "builtin",
    desc = "每 tick/interval poll pred()；真值 resume；需 FrameScheduler/GameSim.schedule_poll",
  },
  wait_real = {
    role = "builtin_opt_in",
    desc = "墙钟等待 seconds；需 scheduler.schedule_real 或 opts.allow_real_time；否则 Failed(wait_real_unsupported)；默认业务禁用",
  },
  chan_send = {
    role = "builtin",
    desc = "有界 channel 发送；满则挂起；关闭 → Failed{tag=chan_closed}",
  },
  chan_recv = {
    role = "builtin",
    desc = "有界 channel 接收；空则挂起；关闭且空 → Failed{tag=chan_closed}",
  },
  chan_close = {
    role = "builtin",
    desc = "关闭 channel；失败等待中的 send；排空后 recv 得 chan_closed",
  },
  when_all = { role = "builtin", desc = "结构化并行：全部 Done 后 resume values 数组" },
  when_any = { role = "builtin", desc = "结构化并行：首个 Done 胜出，其余取消" },
  fork = { role = "builtin", desc = "非结构化并发：启动子任务，立刻 resume handle" },
  join = { role = "builtin", desc = "等待单个 fork handle" },
  join_handles = { role = "builtin", desc = "按序等待多个 fork handle" },
  lane = {
    role = "builtin",
    desc = "命名 fork：session.lanes[name]=id；立刻 resume handle；同名在跑 → Failed(lane_busy)",
  },
  lane_join = {
    role = "builtin",
    desc = "按名等待 lane；未知 → Failed(lane_unknown)；语义同 join",
  },
  lane_stop = {
    role = "builtin",
    desc = "按名合作式停止 lane（Stopped）；resume true/false",
  },
  lane_abort = {
    role = "builtin",
    desc = "按名异常中止 lane（Aborted）；join 不算成功；resume true/false",
  },
  with_timeout = { role = "builtin", desc = "与 wait(deadline) 竞速；超时 → Failed；截止向下传播到 fork" },
  supervise = {
    role = "builtin",
    desc = "监督重启：子 Failed（可选 Stopped）时按 max_restarts/backoff 再启；cancel 不重启",
  },
  anim = {
    role = "demo",
    desc = "演示用异步动画；工程侧自行 register(async=true)",
  },
  connect = {
    role = "legacy_demo",
    desc = "教学 mock 联网；fx.default_handlers.connect",
  },
  click = {
    role = "legacy_demo",
    desc = "教学 mock 点击；fx.default_handlers.click",
  },
}

--- register(kind, handler, opts?)
-- opts.async=true：handler(req, resume)；否则 handler(req)→value
-- opts.meta：可选元数据表（文档/调试）
function M.register(kind, handler, opts)
  assert(type(kind) == "string" and kind ~= "", "fx_registry.register: kind must be non-empty string")
  assert(type(handler) == "function", "fx_registry.register: handler must be function")
  opts = opts or {}
  _entries[kind] = {
    handler = handler,
    async = not not opts.async,
    meta = opts.meta,
  }
  return M
end

--- unregister(kind) → bool（是否原先存在）
function M.unregister(kind)
  if _entries[kind] == nil then
    return false
  end
  _entries[kind] = nil
  return true
end

function M.get(kind)
  return _entries[kind]
end

function M.has(kind)
  return _entries[kind] ~= nil
end

--- 已注册 kind 名列表（排序）
function M.list()
  local names = {}
  for k, _ in pairs(_entries) do
    names[#names + 1] = k
  end
  table.sort(names)
  return names
end

--- 清空（测试用）
function M.clear()
  for k, _ in pairs(_entries) do
    _entries[k] = nil
  end
end

--- 把注册表合并进 handlers 表；async 写入 handlers.__async_kinds
-- 不覆盖已有同名 handler（调用方先放 registry、再放 overrides）。
function M.apply_to_handlers(handlers)
  handlers = handlers or {}
  local async = handlers.__async_kinds
  if type(async) ~= "table" then
    async = {}
    handlers.__async_kinds = async
  end
  for kind, ent in pairs(_entries) do
    if handlers[kind] == nil then
      handlers[kind] = ent.handler
    end
    if ent.async and async[kind] == nil then
      async[kind] = true
    end
  end
  return handlers
end

--- 合并顺序：base → registry → overrides；返回新表
function M.merge_handlers(base, overrides)
  local h = {}
  local async = {}
  if type(base) == "table" then
    for k, v in pairs(base) do
      if k ~= "__async_kinds" then
        h[k] = v
      end
    end
    if type(base.__async_kinds) == "table" then
      for k, v in pairs(base.__async_kinds) do
        async[k] = v
      end
    end
  end
  for kind, ent in pairs(_entries) do
    if h[kind] == nil then
      h[kind] = ent.handler
    end
    if ent.async and async[kind] == nil then
      async[kind] = true
    end
  end
  if type(overrides) == "table" then
    for k, v in pairs(overrides) do
      if k ~= "__async_kinds" then
        h[k] = v
      end
    end
    if type(overrides.__async_kinds) == "table" then
      for k, v in pairs(overrides.__async_kinds) do
        async[k] = v
      end
    end
  end
  h.__async_kinds = async
  return h
end

--- 未知 kind 的 Failed 错误值（结构化，便于业务匹配）
function M.unknown_error(kind)
  return {
    tag = "unknown_effect",
    message = "no handler for kind=" .. tostring(kind),
    effect_kind = kind,
  }
end

return M
