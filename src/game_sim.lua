-- game_sim.lua — 近真实游戏模拟宿主（游戏时间 + 事件 + 实体生命周期）
--
-- 对接 docs/工程对接与后续.md：
--   · 实现 Scheduler：now / schedule / cancel（pause 时时间不推进）
--   · tick(dt) 推进游戏时间、触发到期 timer、poll wait_until、派发事件
--   · schedule_poll(pred, cb, opts?)：与 FrameScheduler 同契约（每帧谓词）
--   · emit / listen → 兑现 fx.wait_event
--   · spawn/destroy_entity → 取消绑定 flow（finally 经 Coro.force_stop）
--   · start_flow / run：把本 sim 作为 opts.scheduler 交给 fx_sched
--   · 实体绑定经 fx_flow.bind_entity（与 Unity OnDestroy 同模式）
--   · register 写入本 sim；亦合并 fx 全局注册表（fx.register）
--
-- Scheduler 方法支持点调用（fx_sched 用 sim.schedule(d,cb)）与冒号调用。
-- 不使用 Lua 原生 coroutine 做业务；Cont-only CPS。

local Sched = require("fx_sched")
local Flow = require("fx_flow")
local Registry = require("fx_registry")

local GameSim = {}
GameSim.__index = GameSim

--- 兼容 obj.fn(a,b) 与 obj:fn(a,b)
local function dual(self, a, b, c)
  if a == self then
    return b, c
  end
  return a, b
end

------------------------------------------------------------
-- 构造
------------------------------------------------------------

--- GameSim.new(opts?) → sim
-- opts.dt：run() 默认步长（秒，默认 1/30）
function GameSim.new(opts)
  opts = opts or {}
  local self = setmetatable({
    _time = 0,
    _paused = false,
    _next_timer_id = 0,
    _timers = {},
    _polls = {},
    _next_listen_id = 0,
    _listeners = {},
    _next_entity_id = 0,
    _entities = {},
    _flows = {},
    _kind_handlers = {},
    _async_kinds = {},
    _dt_default = opts.dt or (1 / 30),
  }, GameSim)

  -- Scheduler 接口（闭包，供 fx_sched 点调用）
  function self.now(...)
    local _ = dual(self, ...)
    return self._time
  end

  function self.schedule(...)
    local delay, cb = dual(self, ...)
    assert(type(cb) == "function", "GameSim.schedule: cb must be function")
    delay = delay or 0
    self._next_timer_id = self._next_timer_id + 1
    local id = self._next_timer_id
    local handle = { id = id, cancelled = false }
    self._timers[id] = {
      due = self._time + delay,
      cb = cb,
      handle = handle,
    }
    return handle
  end

  function self.cancel(...)
    local handle = dual(self, ...)
    if handle == nil then
      return
    end
    handle.cancelled = true
    if handle.id then
      if self._timers[handle.id] then
        self._timers[handle.id] = nil
      end
      if self._polls[handle.id] then
        self._polls[handle.id] = nil
      end
    end
  end

  --- schedule_poll(pred, cb, poll_opts?) → handle（同 FrameScheduler）
  function self.schedule_poll(...)
    local a, b, c = ...
    local pred, cb, poll_opts
    if a == self then
      pred, cb, poll_opts = b, c, select(4, ...)
    else
      pred, cb, poll_opts = a, b, c
    end
    assert(type(pred) == "function", "GameSim.schedule_poll: pred must be function")
    assert(type(cb) == "function", "GameSim.schedule_poll: cb must be function")
    poll_opts = poll_opts or {}
    local interval = poll_opts.interval or 0
    assert(type(interval) == "number" and interval >= 0,
      "GameSim.schedule_poll: interval must be >= 0")
    self._next_timer_id = self._next_timer_id + 1
    local id = self._next_timer_id
    local handle = { id = id, cancelled = false, kind = "poll" }
    self._polls[id] = {
      pred = pred,
      cb = cb,
      handle = handle,
      interval = interval,
      next_at = self._time,
      on_error = poll_opts.on_error,
    }
    return handle
  end

  function self.listen(...)
    local name, filter, cb
    local a, b, c = ...
    if a == self then
      name, filter, cb = b, c, select(4, ...)
    else
      name, filter, cb = a, b, c
    end
    -- filter 可省略：listen(name, cb)
    if type(filter) == "function" and cb == nil then
      cb = filter
      filter = nil
    end
    assert(name ~= nil, "GameSim.listen: name required")
    assert(type(cb) == "function", "GameSim.listen: cb must be function")
    self._next_listen_id = self._next_listen_id + 1
    local id = self._next_listen_id
    local handle = { id = id, cancelled = false }
    self._listeners[id] = {
      id = id,
      name = name,
      filter = filter,
      cb = cb,
      handle = handle,
      cancelled = false,
    }
    return handle
  end

  function self.unlisten(...)
    local handle = dual(self, ...)
    if handle == nil then
      return
    end
    handle.cancelled = true
    local L = handle.id and self._listeners[handle.id]
    if L then
      L.cancelled = true
      self._listeners[handle.id] = nil
    end
  end

  return self
end

------------------------------------------------------------
-- 暂停
------------------------------------------------------------

function GameSim:set_paused(paused)
  self._paused = not not paused
end

function GameSim:is_paused()
  return self._paused
end

------------------------------------------------------------
-- 事件派发
------------------------------------------------------------

--- emit(name, payload?)：立即派发给匹配监听（同帧兑现 wait_event）
function GameSim:emit(name, payload)
  local matched = {}
  for id, L in pairs(self._listeners) do
    if not L.cancelled and L.name == name then
      local ok = true
      if L.filter ~= nil then
        if type(L.filter) == "function" then
          ok = not not L.filter(payload)
        else
          ok = (L.filter == payload)
        end
      end
      if ok then
        matched[#matched + 1] = L
      end
    end
  end
  table.sort(matched, function(a, b)
    return a.id < b.id
  end)
  for _, L in ipairs(matched) do
    self._listeners[L.id] = nil
    L.cancelled = true
    if L.handle then
      L.handle.cancelled = true
    end
    L.cb(payload)
  end
end

------------------------------------------------------------
-- 实体
------------------------------------------------------------

function GameSim:spawn_entity(name)
  self._next_entity_id = self._next_entity_id + 1
  local id = self._next_entity_id
  local ent = { id = id, name = name or ("entity#" .. id), flows = {} }
  self._entities[id] = ent
  return ent
end

function GameSim:destroy_entity(id)
  local ent = self._entities[id]
  if not ent then
    return
  end
  local flows = ent.flows
  ent.flows = {}
  for i = 1, #flows do
    local flow = flows[i]
    if flow and not flow.done and type(flow.cancel) == "function" then
      flow.cancel("entity_destroyed")
    end
  end
  self._entities[id] = nil
end

function GameSim:get_entity(id)
  return self._entities[id]
end

------------------------------------------------------------
-- 效果注册
------------------------------------------------------------

--- register(kind, handler, opts?)
-- opts.async=true：handler(req, resume)；否则 handler(req)→value
function GameSim:register(kind, handler, reg_opts)
  assert(type(kind) == "string", "GameSim.register: kind must be string")
  assert(type(handler) == "function", "GameSim.register: handler must be function")
  reg_opts = reg_opts or {}
  self._kind_handlers[kind] = handler
  if reg_opts.async then
    self._async_kinds[kind] = true
  else
    self._async_kinds[kind] = nil
  end
end

function GameSim:unregister(kind)
  if self._kind_handlers[kind] == nil then
    return false
  end
  self._kind_handlers[kind] = nil
  self._async_kinds[kind] = nil
  return true
end

------------------------------------------------------------
-- tick
------------------------------------------------------------

local function fire_due_timers(self)
  local due = {}
  for id, t in pairs(self._timers) do
    if not t.handle.cancelled and t.due <= self._time + 1e-12 then
      due[#due + 1] = { id = id, t = t }
    end
  end
  table.sort(due, function(a, b)
    if a.t.due == b.t.due then
      return a.id < b.id
    end
    return a.t.due < b.t.due
  end)
  for _, item in ipairs(due) do
    self._timers[item.id] = nil
    if not item.t.handle.cancelled then
      item.t.cb()
    end
  end
end

local function run_polls(self)
  local ids = {}
  for id, _ in pairs(self._polls) do
    ids[#ids + 1] = id
  end
  table.sort(ids)
  for _, id in ipairs(ids) do
    local p = self._polls[id]
    if p and not p.handle.cancelled and self._time + 1e-12 >= p.next_at then
      local ok, result = pcall(p.pred)
      if not ok then
        self._polls[id] = nil
        p.handle.cancelled = true
        if type(p.on_error) == "function" then
          p.on_error(result)
        else
          error(result)
        end
      elseif result then
        self._polls[id] = nil
        p.handle.cancelled = true
        p.cb(result)
      else
        p.next_at = self._time + p.interval
      end
    end
  end
end

function GameSim:tick(dt)
  dt = dt or self._dt_default
  if dt < 0 then
    dt = 0
  end
  if not self._paused then
    self._time = self._time + dt
    fire_due_timers(self)
    run_polls(self)
  end
end

------------------------------------------------------------
-- Flow
------------------------------------------------------------

local function merge_handlers(self, overrides)
  -- 全局注册表 → sim 本地 register → 调用方覆盖
  local base = {}
  local async = {}
  Registry.apply_to_handlers(base)
  if type(base.__async_kinds) == "table" then
    for k, v in pairs(base.__async_kinds) do
      async[k] = v
    end
  end
  for k, v in pairs(self._kind_handlers) do
    base[k] = v
  end
  for k, v in pairs(self._async_kinds) do
    if v then
      async[k] = true
    end
  end
  if type(overrides) == "table" then
    for k, v in pairs(overrides) do
      if k ~= "__async_kinds" then
        base[k] = v
      end
    end
    if type(overrides.__async_kinds) == "table" then
      for k, v in pairs(overrides.__async_kinds) do
        async[k] = v
      end
    end
  end
  base.__async_kinds = async
  return base, async
end

--- start_flow(entity_or_nil, ma, handlers?, opts?) → flow
function GameSim:start_flow(entity_or_nil, ma, handlers, opts)
  assert(ma ~= nil, "GameSim.start_flow: ma required")
  opts = opts or {}
  local h, async_kinds = merge_handlers(self, handlers)

  local sched_opts = {
    scheduler = self,
    async_kinds = async_kinds,
    cancel = opts.cancel,
    verbose_wait = opts.verbose_wait,
  }

  local flow = Flow.start_flow(ma, h, sched_opts)
  self._flows[#self._flows + 1] = flow

  if entity_or_nil ~= nil then
    local ent = entity_or_nil
    if type(ent) == "number" then
      ent = self._entities[ent]
    end
    if ent ~= nil then
      Flow.bind_entity(flow, ent, {
        on_destroy = "cancel",
        reason = "entity_destroyed",
      })
    end
  end

  return flow
end

--- run(ma, handlers?, opts?) → result；固定 dt tick 直到终态
function GameSim:run(ma, handlers, opts)
  opts = opts or {}
  local flow = self:start_flow(nil, ma, handlers, opts)
  if flow.done then
    return flow.result
  end
  local dt = opts.dt or self._dt_default
  local max_ticks = opts.max_ticks or 100000
  local n = 0
  while not flow.done do
    self:tick(dt)
    n = n + 1
    if n > max_ticks then
      error(string.format(
        "GameSim.run: exceeded max_ticks=%d (game_time=%.3f)", max_ticks, self._time))
    end
  end
  return flow.result
end

return GameSim
