#!/usr/bin/env lua
-- trace_export.lua — 跑小型 Cont/fx 场景，把 opts.trace 事件收集写入 JSON 文件
-- 用法（仓库根）：
--   lua5.3 tools/trace_export.lua
--   lua5.3 tools/trace_export.lua --lane --chan
--   lua5.3 tools/trace_export.lua --out /tmp/trace.json
--   lua5.3 tools/trace_export.lua --lane --chan --out tools/trace_out.json
-- 默认输出：tools/trace_out.json
-- 场景拼装：tools/scenarios/（wait_vc + 可选 lane_pair / chan_ping）
-- 详见 tools/README.md、docs/工具速查.md

package.path = "src/?.lua;tools/?.lua;tools/?/init.lua;" .. package.path

local fx = require("fx")
local Sched = require("fx_sched")
local Scheduler = require("scheduler")
local Scenarios = require("scenarios")

local DEFAULT_OUT = "tools/trace_out.json"

local function usage()
  print([[trace_export — 收集 opts.trace 事件到 JSON 文件

用法:
  lua5.3 tools/trace_export.lua [选项]

选项:
  --lane          额外演示命名 lane + lane_join（事件含 lane=）
  --chan          额外演示 chan send/recv（事件含 kind=chan_*）
  --wait <sec>    wait 秒数（默认 0.02）；亦支持 --wait=0.05
  --out PATH      输出 JSON 路径（默认 tools/trace_out.json）
  --stdout        同时把 JSON 打到 stdout
  --help, -h      本说明

说明:
  opts.trace 须为 function（传 true 会被忽略）。
  输出为单个 JSON 对象：{"meta":{...},"events":[{...},...]}
  场景来自 tools/scenarios（wait_vc + 可选 lane_pair / chan_ping）。
  文本 dump 请用 tools/trace_dump.lua。
]])
end

local wait_s = 0.02
local demo_lane = false
local demo_chan = false
local out_path = DEFAULT_OUT
local also_stdout = false
do
  local args = arg or {}
  local i = 1
  while i <= #args do
    local a = args[i]
    if a == "--help" or a == "-h" then
      usage()
      os.exit(0)
    elseif a == "--lane" then
      demo_lane = true
    elseif a == "--chan" then
      demo_chan = true
    elseif a == "--stdout" then
      also_stdout = true
    elseif a:sub(1, 6) == "--out=" then
      out_path = a:sub(7)
    elseif a == "--out" then
      i = i + 1
      out_path = args[i]
      if not out_path then
        io.stderr:write("--out requires PATH\n")
        os.exit(2)
      end
    elseif a:sub(1, 7) == "--wait=" then
      wait_s = tonumber(a:sub(8)) or wait_s
    elseif a == "--wait" then
      i = i + 1
      wait_s = tonumber(args[i]) or wait_s
    else
      io.stderr:write("unknown arg: " .. tostring(a) .. " (try --help)\n")
      os.exit(2)
    end
    i = i + 1
  end
end

------------------------------------------------------------
-- JSON helpers（扁平事件；嵌套 table 压成字符串）
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
    return tostring(v)
  elseif t == "boolean" then
    return tostring(v)
  elseif t == "nil" then
    return "null"
  elseif t == "table" then
    local bits = {}
    for kk, vv in pairs(v) do
      bits[#bits + 1] = tostring(kk) .. "=" .. tostring(vv)
    end
    table.sort(bits)
    return '"' .. esc("{" .. table.concat(bits, ",") .. "}") .. '"'
  else
    return '"' .. esc(v) .. '"'
  end
end

local function encode_event_line(ev)
  local parts = {}
  for k, v in pairs(ev) do
    parts[#parts + 1] = string.format('"%s":%s', k, encode_value(v))
  end
  table.sort(parts)
  return "{" .. table.concat(parts, ",") .. "}"
end

------------------------------------------------------------
-- Scenario：tools/scenarios + opts.trace 收集
------------------------------------------------------------

local events = {}
local function on_trace(ev)
  events[#events + 1] = ev
end

local clock = Scheduler.VirtualClock()
local steps = {
  Scenarios.by_id.wait_vc.build({ wait = wait_s, value = "ok" }),
}

if demo_lane then
  steps[#steps + 1] = Scenarios.by_id.lane_pair.build({ lane = "demo", value = 42 })
end

if demo_chan then
  steps[#steps + 1] = Scenarios.by_id.chan_ping.build({ msg = "ping" })
end

local ma = fx.seq(steps)
local flow = Sched.start_session(ma, {}, { scheduler = clock, trace = on_trace })
clock.advance(wait_s + 0.001)

local ok = flow.result and flow.result.ok
local meta = {
  tool = "tools/trace_export.lua",
  lua = _VERSION,
  wait = wait_s,
  lane = demo_lane,
  chan = demo_chan,
  event_count = #events,
  flow_done = flow.done == true,
  flow_ok = ok == true,
}

local ev_lines = {}
for idx, ev in ipairs(events) do
  local comma = (idx < #events) and "," or ""
  ev_lines[#ev_lines + 1] = "    " .. encode_event_line(ev) .. comma
end

local body = string.format([[{
  "meta": {
    "tool": "%s",
    "lua": "%s",
    "wait": %.4f,
    "lane": %s,
    "chan": %s,
    "event_count": %d,
    "flow_done": %s,
    "flow_ok": %s
  },
  "events": [
%s
  ]
}
]],
  esc(meta.tool), esc(meta.lua), meta.wait,
  tostring(meta.lane), tostring(meta.chan),
  meta.event_count, tostring(meta.flow_done), tostring(meta.flow_ok),
  table.concat(ev_lines, "\n")
)

local f, err = io.open(out_path, "w")
if not f then
  io.stderr:write("trace_export: cannot write " .. out_path .. ": " .. tostring(err) .. "\n")
  os.exit(1)
end
f:write(body)
f:close()

io.stderr:write(string.format(
  "trace_export: wrote %s  (%d events, done=%s ok=%s)\n",
  out_path, #events, tostring(flow.done), tostring(ok)
))

if also_stdout then
  io.stdout:write(body)
end

if not flow.done or not ok then
  io.stderr:write("trace_export: scenario did not settle ok\n")
  os.exit(1)
end
os.exit(0)
