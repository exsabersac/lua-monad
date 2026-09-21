#!/usr/bin/env lua
-- profile_flow.lua — 用 wrapping tracer 给 Cont/fx 场景打点（os.clock / 墙钟间隔）
-- 用法（仓库根）：
--   lua5.3 tools/profile_flow.lua
--   lua5.3 tools/profile_flow.lua 50
--   lua5.3 tools/profile_flow.lua --json
--   lua5.3 tools/profile_flow.lua --smoke
--   lua5.3 tools/profile_flow.lua --json --out tools/profile_out.json
-- 场景：sync seq / wait VirtualClock / lane / chan
-- 详见 tools/README.md、docs/性能与工具.md

package.path = "src/?.lua;" .. package.path

local Cont = require("cont")
local fx = require("fx")
local Sched = require("fx_sched")
local Scheduler = require("scheduler")

------------------------------------------------------------
-- CLI
------------------------------------------------------------

local function usage()
  print([[profile_flow — Cont/fx 场景 + wrapping tracer（os.clock 打点）

用法:
  lua5.3 tools/profile_flow.lua [N] [选项]

选项:
  --json            输出单个 JSON（meta + scenarios + top_kinds）
  --out PATH        与 --json 联用：写入文件（默认 stdout）；亦支持 --out=PATH
  --smoke           极小 N（=1）快速冒烟（CI 默认）
  --filter NAME     只跑名称包含 NAME 的场景（大小写不敏感）
  --top K           打印/导出前 K 个 kind（默认 12）
  --help, -h        本说明

N 默认 20；--smoke 时强制 N=1。
每个 trace 事件记录 t_clock=os.clock()；相邻事件 Δ 归入
  · yield/resume 的 kind（若有）
  · 否则 type
  · 若有 step / name / lane 则附带 step=…
并汇总 top kinds by total time。
]])
end

local N = 20
local json_mode = false
local smoke = false
local filter = nil
local top_k = 12
local out_path = nil
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
    elseif a == "--smoke" then
      smoke = true
    elseif a:sub(1, 6) == "--out=" then
      out_path = a:sub(7)
      json_mode = true
    elseif a == "--out" then
      i = i + 1
      out_path = args[i]
      if not out_path then
        io.stderr:write("--out requires PATH\n")
        os.exit(2)
      end
      json_mode = true
    elseif a:sub(1, 9) == "--filter=" then
      filter = a:sub(10)
    elseif a == "--filter" then
      i = i + 1
      filter = args[i]
    elseif a:sub(1, 6) == "--top=" then
      top_k = tonumber(a:sub(7)) or top_k
    elseif a == "--top" then
      i = i + 1
      top_k = tonumber(args[i]) or top_k
    elseif a:match("^%-") then
      io.stderr:write("unknown arg: " .. tostring(a) .. " (try --help)\n")
      os.exit(2)
    else
      local n = tonumber(a)
      if n then
        N = math.max(1, math.floor(n))
      else
        io.stderr:write("unknown arg: " .. tostring(a) .. " (try --help)\n")
        os.exit(2)
      end
    end
    i = i + 1
  end
end

if smoke then
  N = 1
end

local function match_filter(name)
  if filter == nil or filter == "" then
    return true
  end
  return name:lower():find(filter:lower(), 1, true) ~= nil
end

------------------------------------------------------------
-- JSON helpers
------------------------------------------------------------

local function esc(s)
  s = tostring(s)
  return (s:gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\n", "\\n"):gsub("\r", "\\r"))
end

local function encode_value(v)
  local t = type(v)
  if t == "number" then
    if v ~= v then
      return "null"
    end
    -- keep enough digits for tiny dt
    if math.floor(v) == v and math.abs(v) < 1e15 then
      return string.format("%.0f", v)
    end
    return string.format("%.9g", v)
  elseif t == "boolean" then
    return tostring(v)
  elseif t == "nil" then
    return "null"
  elseif t == "table" then
    -- array?
    local n = #v
    local is_arr = true
    for k in pairs(v) do
      if type(k) ~= "number" then
        is_arr = false
        break
      end
    end
    if is_arr then
      local parts = {}
      for i = 1, n do
        parts[i] = encode_value(v[i])
      end
      return "[" .. table.concat(parts, ",") .. "]"
    end
    local keys = {}
    for k in pairs(v) do
      keys[#keys + 1] = k
    end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    local parts = {}
    for _, k in ipairs(keys) do
      parts[#parts + 1] = string.format('"%s":%s', esc(k), encode_value(v[k]))
    end
    return "{" .. table.concat(parts, ",") .. "}"
  else
    return '"' .. esc(v) .. '"'
  end
end

------------------------------------------------------------
-- Wrapping tracer：记录 os.clock；Δ 归 kind / step
------------------------------------------------------------

local function bucket_key(ev)
  local kind = ev.kind
  local typ = ev.type or "?"
  local step = ev.step or ev.name or ev.lane
  local base
  if kind ~= nil and kind ~= "" then
    base = tostring(kind)
  else
    base = tostring(typ)
  end
  if step ~= nil and step ~= "" then
    return base .. "|step=" .. tostring(step), base, tostring(step)
  end
  return base, base, nil
end

local function make_profiler()
  local state = {
    events = {},
    by_kind = {}, -- key -> { kind, step, count, total_clock, total_wall }
    last_clock = nil,
    last_wall = nil,
    t0_clock = nil,
    t0_wall = nil,
  }

  -- wall：优先 socket.gettime（若已安装）；否则退回 os.clock（与 CPU 同刻度，仍可算间隔）
  local wall_now
  local wall_src = "os.clock"
  local ok_sock, socket = pcall(require, "socket")
  if ok_sock and socket and type(socket.gettime) == "function" then
    wall_now = function() return socket.gettime() end
    wall_src = "socket.gettime"
  else
    wall_now = function() return os.clock() end
  end

  local function on_trace(ev)
    local c = os.clock()
    local w = wall_now()
    if state.t0_clock == nil then
      state.t0_clock = c
      state.t0_wall = w
    end
    local dt_c = 0
    local dt_w = 0
    if state.last_clock ~= nil then
      dt_c = c - state.last_clock
      dt_w = w - state.last_wall
      -- 上一段时间归入「上一事件」的 bucket（事件发生后到下一事件前的成本）
      local prev = state.events[#state.events]
      if prev then
        local key, kind, step = bucket_key(prev.ev)
        local agg = state.by_kind[key]
        if not agg then
          agg = { kind = kind, step = step, count = 0, total_clock = 0, total_wall = 0 }
          state.by_kind[key] = agg
        end
        agg.count = agg.count + 1
        agg.total_clock = agg.total_clock + dt_c
        agg.total_wall = agg.total_wall + dt_w
      end
    end
    local rec = {
      ev = ev,
      t_clock = c,
      t_wall = w,
      dt_clock = dt_c,
      dt_wall = dt_w,
      i = #state.events + 1,
    }
    state.events[#state.events + 1] = rec
    state.last_clock = c
    state.last_wall = w
  end

  local function finish()
    -- 末事件后到 finish 的尾巴也归入末事件
    local c = os.clock()
    local w = wall_now()
    if state.last_clock ~= nil and #state.events > 0 then
      local dt_c = c - state.last_clock
      local dt_w = w - state.last_wall
      local prev = state.events[#state.events]
      local key, kind, step = bucket_key(prev.ev)
      local agg = state.by_kind[key]
      if not agg then
        agg = { kind = kind, step = step, count = 0, total_clock = 0, total_wall = 0 }
        state.by_kind[key] = agg
      end
      agg.count = agg.count + 1
      agg.total_clock = agg.total_clock + dt_c
      agg.total_wall = agg.total_wall + dt_w
      prev.dt_tail_clock = dt_c
      prev.dt_tail_wall = dt_w
    end
    state.t1_clock = c
    state.t1_wall = w
    state.wall_src = wall_src
  end

  local function ranked()
    local rows = {}
    for key, agg in pairs(state.by_kind) do
      rows[#rows + 1] = {
        key = key,
        kind = agg.kind,
        step = agg.step,
        count = agg.count,
        total_clock = agg.total_clock,
        total_wall = agg.total_wall,
      }
    end
    table.sort(rows, function(a, b)
      if a.total_clock ~= b.total_clock then
        return a.total_clock > b.total_clock
      end
      return a.key < b.key
    end)
    return rows
  end

  return {
    on_trace = on_trace,
    finish = finish,
    state = state,
    ranked = ranked,
    wall_src = function() return wall_src end,
  }
end

------------------------------------------------------------
-- Scenarios
------------------------------------------------------------

local function run_once(build_ma, opts_extra)
  local prof = make_profiler()
  local clock = Scheduler.VirtualClock()
  local opts = { scheduler = clock, trace = prof.on_trace }
  if opts_extra then
    for k, v in pairs(opts_extra) do
      opts[k] = v
    end
  end
  local ma = build_ma()
  local flow = Sched.start_session(ma, {}, opts)
  -- 推进虚拟时间直到 settled（多数场景 wait 很小）
  local guard = 0
  while not flow.done and guard < 10000 do
    clock.advance(0.05)
    guard = guard + 1
  end
  prof.finish()
  return flow, prof
end

local scenarios = {
  {
    name = "sync seq",
    build = function()
      return fx.seq({
        Cont.unit(1),
        Cont.unit(2),
        Cont.unit(3),
      })
    end,
  },
  {
    name = "wait VirtualClock",
    build = function()
      return fx.seq({
        fx.wait(0.01),
        Cont.unit("after-wait"),
      })
    end,
  },
  {
    name = "lane",
    build = function()
      return fx.lane("p", Cont.unit(7)) >> function(_)
        return fx.lane_join("p")
      end
    end,
  },
  {
    name = "chan",
    build = function()
      local ch = fx.chan()
      return fx.fork(fx.send(ch, "ping")) >> function(h)
        return fx.recv(ch) >> function(v)
          return fx.join(h) >> function()
            return Cont.unit(v)
          end
        end
      end
    end,
  },
}

------------------------------------------------------------
-- Run
------------------------------------------------------------

local results = {}
local global_by_kind = {}

local function merge_global(rows)
  for _, r in ipairs(rows) do
    local g = global_by_kind[r.key]
    if not g then
      g = { key = r.key, kind = r.kind, step = r.step, count = 0, total_clock = 0, total_wall = 0 }
      global_by_kind[r.key] = g
    end
    g.count = g.count + r.count
    g.total_clock = g.total_clock + r.total_clock
    g.total_wall = g.total_wall + r.total_wall
  end
end

local wall_src_seen = "os.clock"
local any_fail = false

for _, sc in ipairs(scenarios) do
  if match_filter(sc.name) then
    local total_clock = 0
    local total_wall = 0
    local event_count = 0
    local ok_count = 0
    local last_prof = nil
    local merged = {}

    for _ = 1, N do
      local flow, prof = run_once(sc.build)
      last_prof = prof
      wall_src_seen = prof.state.wall_src or wall_src_seen
      local st = prof.state
      local elapsed_c = (st.t1_clock or 0) - (st.t0_clock or 0)
      local elapsed_w = (st.t1_wall or 0) - (st.t0_wall or 0)
      total_clock = total_clock + elapsed_c
      total_wall = total_wall + elapsed_w
      event_count = event_count + #st.events
      if flow.done and flow.result and flow.result.ok then
        ok_count = ok_count + 1
      else
        any_fail = true
      end
      for _, row in ipairs(prof.ranked()) do
        local m = merged[row.key]
        if not m then
          m = { key = row.key, kind = row.kind, step = row.step, count = 0, total_clock = 0, total_wall = 0 }
          merged[row.key] = m
        end
        m.count = m.count + row.count
        m.total_clock = m.total_clock + row.total_clock
        m.total_wall = m.total_wall + row.total_wall
      end
    end

    local rows = {}
    for _, m in pairs(merged) do
      rows[#rows + 1] = m
    end
    table.sort(rows, function(a, b)
      if a.total_clock ~= b.total_clock then
        return a.total_clock > b.total_clock
      end
      return a.key < b.key
    end)
    merge_global(rows)

    results[#results + 1] = {
      name = sc.name,
      n = N,
      ok = ok_count,
      events = event_count,
      sec_clock = total_clock,
      sec_wall = total_wall,
      top = rows,
      wall_src = last_prof and last_prof.state.wall_src or wall_src_seen,
    }
  end
end

local global_rows = {}
for _, g in pairs(global_by_kind) do
  global_rows[#global_rows + 1] = g
end
table.sort(global_rows, function(a, b)
  if a.total_clock ~= b.total_clock then
    return a.total_clock > b.total_clock
  end
  return a.key < b.key
end)

local function take_top(rows, k)
  local out = {}
  for i = 1, math.min(k, #rows) do
    out[i] = rows[i]
  end
  return out
end

------------------------------------------------------------
-- Emit
------------------------------------------------------------

if json_mode then
  local payload = {
    meta = {
      tool = "tools/profile_flow.lua",
      lua = _VERSION,
      n = N,
      smoke = smoke,
      wall_src = wall_src_seen,
      scenario_count = #results,
    },
    scenarios = {},
    top_kinds = {},
  }
  for _, r in ipairs(results) do
    local tops = {}
    for _, t in ipairs(take_top(r.top, top_k)) do
      tops[#tops + 1] = {
        key = t.key,
        kind = t.kind,
        step = t.step,
        count = t.count,
        total_clock = t.total_clock,
        total_wall = t.total_wall,
      }
    end
    payload.scenarios[#payload.scenarios + 1] = {
      name = r.name,
      n = r.n,
      ok = r.ok,
      events = r.events,
      sec_clock = r.sec_clock,
      sec_wall = r.sec_wall,
      top_kinds = tops,
    }
  end
  for _, t in ipairs(take_top(global_rows, top_k)) do
    payload.top_kinds[#payload.top_kinds + 1] = {
      key = t.key,
      kind = t.kind,
      step = t.step,
      count = t.count,
      total_clock = t.total_clock,
      total_wall = t.total_wall,
    }
  end

  local body = encode_value(payload) .. "\n"
  if out_path then
    local f, err = io.open(out_path, "w")
    if not f then
      io.stderr:write("profile_flow: cannot write " .. out_path .. ": " .. tostring(err) .. "\n")
      os.exit(1)
    end
    f:write(body)
    f:close()
    io.stderr:write(string.format(
      "profile_flow: wrote %s  (scenarios=%d n=%d wall_src=%s)\n",
      out_path, #results, N, wall_src_seen
    ))
  else
    io.stdout:write(body)
  end
else
  print(string.format("profile_flow  N=%d  wall_src=%s  scenarios=%d",
    N, wall_src_seen, #results))
  print(string.rep("-", 72))
  for _, r in ipairs(results) do
    print(string.format("[%s]  ok=%d/%d  events=%d  sec_clock=%.6f  sec_wall=%.6f",
      r.name, r.ok, r.n, r.events, r.sec_clock, r.sec_wall))
    local tops = take_top(r.top, top_k)
    if #tops == 0 then
      print("  (no kind buckets)")
    else
      print(string.format("  %-28s %8s %12s %12s", "kind[/step]", "count", "Σclock", "Σwall"))
      for _, t in ipairs(tops) do
        local label = t.key
        if #label > 28 then
          label = label:sub(1, 25) .. "..."
        end
        print(string.format("  %-28s %8d %12.6f %12.6f",
          label, t.count, t.total_clock, t.total_wall))
      end
    end
    print("")
  end
  print("== top kinds (all scenarios) ==")
  print(string.format("  %-28s %8s %12s %12s", "kind[/step]", "count", "Σclock", "Σwall"))
  for _, t in ipairs(take_top(global_rows, top_k)) do
    local label = t.key
    if #label > 28 then
      label = label:sub(1, 25) .. "..."
    end
    print(string.format("  %-28s %8d %12.6f %12.6f",
      label, t.count, t.total_clock, t.total_wall))
  end
end

if any_fail then
  io.stderr:write("profile_flow: one or more scenario runs did not settle ok\n")
  os.exit(1)
end
os.exit(0)
