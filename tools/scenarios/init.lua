-- tools/scenarios — 小型可复用 Cont/fx 场景（bench / profile / trace 共用）
-- 用法（仓库根，先扩展 package.path）：
--   package.path = "src/?.lua;tools/?.lua;tools/?/init.lua;" .. package.path
--   local Scenarios = require("scenarios")
--   local ma = Scenarios.by_id.sync_seq.build()
--   for _, sc in ipairs(Scenarios.list) do ... end
--
-- 模块：sync_seq / wait_vc / lane_pair / chan_ping / supervise_once
-- 每个模块：{ id, name, needs_scheduler, build(opts?) → Cont }

local ORDER = {
  "sync_seq",
  "wait_vc",
  "lane_pair",
  "chan_ping",
  "supervise_once",
}

local M = {
  list = {},
  by_id = {},
  ORDER = ORDER,
}

for _, id in ipairs(ORDER) do
  local mod = require("scenarios." .. id)
  M.list[#M.list + 1] = mod
  M.by_id[id] = mod
end

--- @param id_or_name string  id（sync_seq）或展示名（sync seq）
--- @return table|nil
function M.get(id_or_name)
  if id_or_name == nil then
    return nil
  end
  local hit = M.by_id[id_or_name]
  if hit then
    return hit
  end
  local needle = tostring(id_or_name):lower()
  for _, mod in ipairs(M.list) do
    if mod.id == id_or_name or (mod.name and mod.name:lower() == needle) then
      return mod
    end
  end
  return nil
end

--- 按 name 子串过滤（大小写不敏感）；空 filter 返回全部
--- @param filter? string
--- @return table[]
function M.filter(filter)
  if filter == nil or filter == "" then
    local out = {}
    for i, mod in ipairs(M.list) do
      out[i] = mod
    end
    return out
  end
  local needle = tostring(filter):lower()
  local out = {}
  for _, mod in ipairs(M.list) do
    local name = (mod.name or mod.id or ""):lower()
    local id = (mod.id or ""):lower()
    if name:find(needle, 1, true) or id:find(needle, 1, true) then
      out[#out + 1] = mod
    end
  end
  return out
end

return M
