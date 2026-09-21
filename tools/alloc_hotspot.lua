#!/usr/bin/env lua
-- alloc_hotspot.lua — Cont >> 链分配热点快照（collectgarbage count）
-- 在仓库根目录：
--   lua5.3 tools/alloc_hotspot.lua
--   lua5.3 tools/alloc_hotspot.lua 5000
--   lua5.3 tools/alloc_hotspot.lua --json 10000
-- 详见 tools/README.md、docs/性能与工具.md

package.path = "src/?.lua;" .. package.path

local Cont = require("cont")

------------------------------------------------------------
-- CLI
------------------------------------------------------------

local function usage()
  print([[alloc_hotspot — Cont >> 链分配热点

用法:
  lua5.3 tools/alloc_hotspot.lua [N] [选项]

选项:
  --json         machine-readable 单行 JSON
  --map          额外跑 Cont.map 链对照
  --help, -h     本说明

N 默认 5000。报告 collectgarbage("count") before/after/ΔKB；
并用「新建表计数启发式」估算代理表压力（debug.getregistry 不可靠时仅作相对参考）。
]])
end

local N = 5000
local json_mode = false
local do_map = false
do
  local args = arg or {}
  local i = 1
  while i <= #args do
    local a = args[i]
    if a == "--help" or a == "-h" then
      usage()
      os.exit(0)
    elseif a == "--json" then
      json_mode = true
    elseif a == "--map" then
      do_map = true
    elseif a:match("^%-") then
      io.stderr:write("unknown arg: " .. tostring(a) .. " (try --help)\n")
      os.exit(2)
    else
      local n = tonumber(a)
      if n then
        N = n
      else
        io.stderr:write("unknown arg: " .. tostring(a) .. " (try --help)\n")
        os.exit(2)
      end
    end
    i = i + 1
  end
end

------------------------------------------------------------
-- table-count heuristic
-- Lua 5.3 无官方「活表数量」API；用弱表登记 + 短 GC 观察相对增长。
------------------------------------------------------------

local function make_table_probe()
  local weak = setmetatable({}, { __mode = "k" })
  local created = 0
  local function track(t)
    if type(t) == "table" then
      if weak[t] == nil then
        weak[t] = true
        created = created + 1
      end
    end
    return t
  end
  local function snapshot()
    collectgarbage("collect")
    local live = 0
    for _ in pairs(weak) do
      live = live + 1
    end
    return created, live
  end
  return track, snapshot
end

local function measure_bind_chain(n)
  local track, snap = make_table_probe()
  collectgarbage("collect")
  collectgarbage("collect")
  local kb0 = collectgarbage("count")
  local c0, live0 = snap()

  local m = Cont.unit(0)
  track(m)
  for i = 1, n do
    m = m >> function(x)
      local u = Cont.unit(x + 1)
      track(u)
      return u
    end
    track(m)
  end
  local v = Cont.evalCont(m)
  assert(v == n)

  local kb1 = collectgarbage("count")
  local c1, live1 = snap()
  return {
    name = "Cont >> chain",
    n = n,
    kb_before = kb0,
    kb_after = kb1,
    kb_delta = kb1 - kb0,
    tables_created_approx = c1 - c0,
    tables_live_approx = live1,
    tables_live_before_approx = live0,
    result = v,
  }
end

local function measure_map_chain(n)
  local track, snap = make_table_probe()
  collectgarbage("collect")
  collectgarbage("collect")
  local kb0 = collectgarbage("count")
  local c0, live0 = snap()

  local m = Cont.unit(0)
  track(m)
  for _ = 1, n do
    m = Cont.map(m, function(x)
      return x + 1
    end)
    track(m)
  end
  local v = Cont.evalCont(m)
  assert(v == n)

  local kb1 = collectgarbage("count")
  local c1, live1 = snap()
  return {
    name = "Cont.map chain",
    n = n,
    kb_before = kb0,
    kb_after = kb1,
    kb_delta = kb1 - kb0,
    tables_created_approx = c1 - c0,
    tables_live_approx = live1,
    tables_live_before_approx = live0,
    result = v,
  }
end

local function esc_json(s)
  return (tostring(s):gsub("\\", "\\\\"):gsub('"', '\\"'))
end

local function emit(r)
  if json_mode then
    print(string.format(
      '{"name":"%s","n":%d,"kb_before":%.3f,"kb_after":%.3f,"kb_delta":%.3f,'
        .. '"tables_created_approx":%d,"tables_live_approx":%d}',
      esc_json(r.name), r.n, r.kb_before, r.kb_after, r.kb_delta,
      r.tables_created_approx, r.tables_live_approx
    ))
  else
    print(string.format(
      "%-16s N=%d  KB before=%.1f after=%.1f Δ=%.1f  tables≈ created=%d live=%d",
      r.name, r.n, r.kb_before, r.kb_after, r.kb_delta,
      r.tables_created_approx, r.tables_live_approx
    ))
  end
end

if not json_mode then
  print(string.format("alloc_hotspot  N=%d  Lua %s", N, _VERSION))
  print("（表计数为弱表启发式，仅相对参考；非精确 heap 表数）")
end

emit(measure_bind_chain(N))
if do_map then
  emit(measure_map_chain(N))
end

if not json_mode then
  print("done. 对照：lua5.3 tools/bench_cont_fx.lua --alloc --filter 'Cont >>'")
end
