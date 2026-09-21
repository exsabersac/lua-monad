-- fx_flow.lua — flow 启动与实体绑定（工程可复用）
--
-- GameSim / Unity 宿主共用：
--   start_flow(ma, handlers, opts) → flow   （薄封装 fx_sched.start_session）
--   bind_entity(flow, entity, opts?)        （销毁时 cancel）
--   start_bound_flow(entity, ma, ...)       （启动并绑定）
--
-- 实体形态：
--   · table 且有 .flows 数组（GameSim.spawn_entity）→ 自动 append，destroy 时遍历 cancel
--   · 任意 key：仅返回 binding；由宿主在 OnDestroy 调 binding.destroy()
--
-- opts.bind / bind_entity 的 opts：
--   on_destroy = "cancel"（默认）| function(flow, reason) | false（不自动取消）

local Sched = require("fx_sched")

local M = {}

local function resolve_on_destroy(opts)
  opts = opts or {}
  local od = opts.on_destroy
  if od == nil then
    return "cancel"
  end
  return od
end

--- bind_entity(flow, entity_or_key, opts?) → binding
-- binding.destroy(reason?)：按 on_destroy 策略取消 flow
-- binding.flow / binding.entity
function M.bind_entity(flow, entity_or_key, opts)
  assert(flow ~= nil, "fx_flow.bind_entity: flow required")
  opts = opts or {}
  local on_destroy = resolve_on_destroy(opts)
  local reason_default = opts.reason or "entity_destroyed"

  local binding = {
    flow = flow,
    entity = entity_or_key,
    on_destroy = on_destroy,
  }

  function binding.destroy(reason)
    reason = reason or reason_default
    if flow == nil or flow.done then
      return flow and flow.result or nil
    end
    if on_destroy == false or on_destroy == nil then
      return nil
    end
    if on_destroy == "cancel" or on_destroy == true then
      if type(flow.cancel) == "function" then
        return flow.cancel(reason)
      end
      return nil
    end
    if type(on_destroy) == "function" then
      return on_destroy(flow, reason)
    end
    error("fx_flow.bind_entity: opts.on_destroy must be 'cancel'|function|false")
  end

  -- GameSim 风格实体：挂到 ent.flows，destroy_entity 会调 flow.cancel
  if type(entity_or_key) == "table" and type(entity_or_key.flows) == "table" then
    entity_or_key.flows[#entity_or_key.flows + 1] = flow
    if entity_or_key.id ~= nil then
      flow.entity_id = entity_or_key.id
    end
  end

  flow._entity_binding = binding
  return binding
end

--- start_flow(ma, handlers?, opts?) → flow
function M.start_flow(ma, handlers, opts)
  assert(ma ~= nil, "fx_flow.start_flow: ma required")
  return Sched.start_session(ma, handlers, opts)
end

--- start_bound_flow(entity, ma, handlers?, opts?) → flow
-- opts.bind 传给 bind_entity；其余 opts 传给 start_session
function M.start_bound_flow(entity, ma, handlers, opts)
  opts = opts or {}
  local flow = M.start_flow(ma, handlers, opts)
  if entity ~= nil then
    M.bind_entity(flow, entity, opts.bind or {
      on_destroy = opts.on_destroy,
      reason = opts.destroy_reason,
    })
  end
  return flow
end

return M
