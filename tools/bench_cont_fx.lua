#!/usr/bin/env lua
-- bench_cont_fx.lua — Cont / >> / chain / fx 热路径粗测（分配敏感）
-- 在仓库根目录：
--   lua5.3 tools/bench_cont_fx.lua
--   lua5.3 tools/bench_cont_fx.lua 50000
--   lua5.3 tools/bench_cont_fx.lua --json
--   lua5.3 tools/bench_cont_fx.lua --filter lane
--   lua5.3 tools/bench_cont_fx.lua --alloc --json
-- 结果写入 stdout；亦可重定向。非严格 microbench（含 GC）。
-- JSON 含 dkb 与 kb_delta（同值）。详见 tools/README.md、docs/性能与工具.md

package.path = "src/?.lua;tools/?.lua;tools/?/init.lua;" .. package.path

local Cont = require("cont")
local Coro = require("coro")
local fx = require("fx")
local Sched = require("fx_sched")
local Scheduler = require("scheduler")
local GameSim = require("game_sim")
local Scenarios = require("scenarios")

------------------------------------------------------------
-- CLI
------------------------------------------------------------

local function usage()
  print([[bench_cont_fx — Cont / fx 热路径粗测

用法:
  lua5.3 tools/bench_cont_fx.lua [N] [选项]

选项:
  --json            每行一个 JSON 对象（machine-readable）
  --filter NAME     只跑名称包含 NAME 的用例（大小写不敏感）
  --alloc           更清晰的分配报告（KB before/after/Δ；JSON 多 kb_before/kb_after）
  --help, -h        本说明

N 默认 20000；含 wait/session 的用例内部会 clamp。
JSON 字段：name / n / sec / rate / dkb / kb_delta（=dkb）；--alloc 时另有 kb_before / kb_after。
]])
end

local N = 20000
local json_mode = false
local alloc_mode = false
local filter = nil
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
    elseif a == "--alloc" then
      alloc_mode = true
    elseif a:sub(1, 9) == "--filter=" then
      filter = a:sub(10)
    elseif a == "--filter" then
      i = i + 1
      filter = args[i]
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

local function time_call(n, fn)
  collectgarbage("collect")
  collectgarbage("collect")
  local m0 = collectgarbage("count")
  local t0 = os.clock()
  fn(n)
  local t1 = os.clock()
  local m1 = collectgarbage("count")
  return t1 - t0, m1 - m0, m0, m1
end

local function esc_json(s)
  s = tostring(s)
  return (s:gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\n", "\\n"))
end

local function fmt(sec, n, dkb, kb0, kb1)
  local base = string.format("%.3f s  (%.0f /s)  ΔKB=%.1f",
    sec, n / math.max(sec, 1e-12), dkb)
  if alloc_mode and kb0 and kb1 then
    base = base .. string.format("  alloc[KB before=%.1f after=%.1f Δ=%.1f]", kb0, kb1, dkb)
  end
  return base
end

local function emit(name, n, sec, dkb, note, kb0, kb1)
  if json_mode then
    local rate = n / math.max(sec, 1e-12)
    local parts = {
      string.format('"name":"%s"', esc_json(name)),
      string.format('"n":%d', n),
      string.format('"sec":%.6f', sec),
      string.format('"rate":%.3f', rate),
      string.format('"dkb":%.3f', dkb),
      string.format('"kb_delta":%.3f', dkb),
    }
    if alloc_mode and kb0 and kb1 then
      parts[#parts + 1] = string.format('"kb_before":%.3f', kb0)
      parts[#parts + 1] = string.format('"kb_after":%.3f', kb1)
    end
    if note then
      parts[#parts + 1] = string.format('"note":"%s"', esc_json(note))
    end
    print("{" .. table.concat(parts, ",") .. "}")
  else
    local line = string.format("%-20s %s", name, fmt(sec, n, dkb, kb0, kb1))
    if note then
      line = line .. "  " .. note
    end
    print(line)
  end
end

local function match_filter(name)
  if filter == nil or filter == "" then
    return true
  end
  return name:lower():find(filter:lower(), 1, true) ~= nil
end

------------------------------------------------------------
-- Cases
------------------------------------------------------------

local cases = {}

local function add(name, n_or_fn, fn)
  local n, run
  if type(n_or_fn) == "function" then
    n = N
    run = n_or_fn
  else
    n = n_or_fn
    run = fn
  end
  cases[#cases + 1] = { name = name, n = n, run = run }
end

-- 1) Cont.unit >> Cont.unit 链
add("Cont >> chain", function(n)
  local m = Cont.unit(0)
  for i = 1, n do
    m = m >> function(x)
      return Cont.unit(x + 1)
    end
  end
  assert(Cont.evalCont(m) == n)
end)

-- 1a) Cont.map 链
add("Cont.map chain", function(n)
  local m = Cont.unit(0)
  for _ = 1, n do
    m = Cont.map(m, function(x)
      return x + 1
    end)
  end
  assert(Cont.evalCont(m) == n)
end)

-- 1b) Cont.chain
add("Cont.chain", function(n)
  local m = Cont.unit(0)
  for i = 1, n do
    m = Cont.chain(m, Cont.unit(i))
  end
  assert(Cont.evalCont(m) == n)
end)

-- 1c) Cont .. Cont
add("Cont .. chain", function(n)
  local m = Cont.unit(0)
  for i = 1, n do
    m = m .. Cont.unit(i)
  end
  assert(Cont.evalCont(m) == n)
end)

-- 2) Coro.start(unit)
add("Coro.start unit", function(n)
  for _ = 1, n do
    local a = Coro.start(Cont.unit(1))
    assert(Coro.isDone(a) and a.value == 1)
  end
end)

-- 3) fx.seq 短数组 via fx.run（scenarios.sync_seq）
add("fx.seq×3 run", function(n)
  for _ = 1, n do
    local r = fx.run(Scenarios.by_id.sync_seq.build(), {})
    assert(r.ok and r.value == 3)
  end
end)

-- 3b) fx.seq eval only（scenarios.sync_seq）
add("fx.seq×3 eval", function(n)
  for _ = 1, n do
    local m = Scenarios.by_id.sync_seq.build()
    assert(Cont.evalCont(m) == 3)
  end
end)

-- 4) VirtualClock wait(0) session
add("session wait(0)", math.min(N, 5000), function(nn)
  for _ = 1, nn do
    local clock = Scheduler.VirtualClock()
    local flow = Sched.start_session(fx.wait(0) >> function(_)
      return Cont.unit(true)
    end, {}, { scheduler = clock })
    clock.advance(0)
    assert(flow.done and flow.result.ok)
  end
end)

-- 5) fx.lane + lane_join（scenarios.lane_pair；名轮换避免语义依赖）
add("fx.lane+join", math.min(N, 2000), function(n)
  for i = 1, n do
    local name = "L" .. tostring(i % 8)
    local r = fx.run(Scenarios.by_id.lane_pair.build({ lane = name, value = i }))
    assert(r.ok and r.value == i)
  end
end)

-- 6) fx.proxy_join（经命名 lane）
add("fx.proxy_join", math.min(N, 2000), function(n)
  for i = 1, n do
    local name = "P" .. tostring(i % 8)
    local r = fx.run(
      fx.lane(name, Cont.unit(i)) >> function(_)
        return fx.proxy_join(fx.proxy(name))
      end
    )
    assert(r.ok and r.value == i)
  end
end)

-- 7) fx.chan send/recv — VirtualClock session（scenarios.chan_ping）
add("fx.chan VC", math.min(N, 5000), function(nn)
  for _ = 1, nn do
    local clock = Scheduler.VirtualClock()
    local flow = Sched.start_session(
      Scenarios.by_id.chan_ping.build({ msg = 1 }),
      {},
      { scheduler = clock }
    )
    assert(flow.done and flow.result.ok and flow.result.value == 1)
  end
end)

-- 8) fx.chan send/recv — GameSim（scenarios.chan_ping）
add("fx.chan GameSim", math.min(N, 2000), function(nn)
  for _ = 1, nn do
    local sim = GameSim.new({ dt = 1 / 30 })
    local r = sim:run(Scenarios.by_id.chan_ping.build({ msg = "x" }))
    assert(r.ok and r.value == "x")
  end
end)

-- 9) fx.supervise：失败一次后成功（scenarios.supervise_once）
add("fx.supervise", math.min(N, 5000), function(nn)
  for _ = 1, nn do
    local r = fx.run(Scenarios.by_id.supervise_once.build())
    assert(r.ok and r.value == "ok")
  end
end)

-- 10) fx.wait_until 平凡 pred（立刻真）
add("fx.wait_until triv", math.min(N, 5000), function(nn)
  for _ = 1, nn do
    local clock = Scheduler.FrameScheduler()
    local flow = Sched.start_session(
      fx.wait_until(function()
        return true
      end),
      {},
      { scheduler = clock }
    )
    if not flow.done then
      clock.tick(0)
    end
    assert(flow.done and flow.result.ok and flow.result.value == true)
  end
end)

-- 11) when_all of waits（VirtualClock）
add("when_all waits", math.min(N, 2000), function(nn)
  for _ = 1, nn do
    local clock = Scheduler.VirtualClock()
    local flow = Sched.start_session(
      fx.when_all({
        fx.wait(0.01) >> function(_)
          return Cont.unit(1)
        end,
        fx.wait(0.01) >> function(_)
          return Cont.unit(2)
        end,
      }),
      {},
      { scheduler = clock }
    )
    clock.advance(0.01)
    assert(flow.done and flow.result.ok)
    assert(flow.result.value[1] == 1 and flow.result.value[2] == 2)
  end
end)

------------------------------------------------------------
-- Run
------------------------------------------------------------

if not json_mode then
  print(string.format("bench_cont_fx  N=%d  Lua %s%s%s",
    N, _VERSION,
    filter and ("  filter=" .. filter) or "",
    alloc_mode and "  --alloc" or ""))
end

local ran = 0
for _, c in ipairs(cases) do
  if match_filter(c.name) then
    local note = nil
    if c.n ~= N then
      note = string.format("(N=%d)", c.n)
    end
    local sec, dkb, kb0, kb1 = time_call(c.n, c.run)
    emit(c.name, c.n, sec, dkb, note, kb0, kb1)
    ran = ran + 1
  end
end

if ran == 0 then
  io.stderr:write("no cases matched filter: " .. tostring(filter) .. "\n")
  os.exit(2)
end

if not json_mode then
  print("done. （压力：Cont 代理表 + bind/unit；无 Yield 的 fx.run 走 sync fast-path；详见 docs/性能与工具.md）")
end
