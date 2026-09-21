#!/usr/bin/env lua
-- trace_dump.lua — 把 fx/fx_sched trace 事件打印到 stdout（或 --json 一行一 JSON）
-- 用法（仓库根）：
--   lua5.3 tools/trace_dump.lua
--   lua5.3 tools/trace_dump.lua --json
--   lua5.3 tools/trace_dump.lua --wait 0.05
--   lua5.3 tools/trace_dump.lua --help
-- 详见 tools/README.md

package.path = "src/?.lua;" .. package.path

local Cont = require("cont")
local fx = require("fx")
local Sched = require("fx_sched")
local Scheduler = require("scheduler")

local function usage()
  print([[trace_dump — 演示 opts.trace / Sched 追踪事件

用法:
  lua5.3 tools/trace_dump.lua [选项]

选项:
  --json          每行一个 JSON 对象（字段排序）
  --wait <sec>    wait 秒数（默认 0.02）；亦支持 --wait=0.05
  --help, -h      本说明

说明:
  opts.trace 须为 function（传 true 会被忽略）。
  也可用 Sched.set_tracer / fx.set_tracer 设全局 tracer。
]])
end

local json_mode = false
local wait_s = 0.02
local i = 1
local args = arg or {}
while i <= #args do
  local a = args[i]
  if a == "--help" or a == "-h" then
    usage()
    os.exit(0)
  elseif a == "--json" then
    json_mode = true
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

local function esc(s)
  s = tostring(s)
  return (s:gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\n", "\\n"))
end

local function dump_ev(ev)
  if json_mode then
    local parts = {}
    for k, v in pairs(ev) do
      local vs
      if type(v) == "number" or type(v) == "boolean" then
        vs = tostring(v)
      elseif type(v) == "nil" then
        vs = "null"
      else
        vs = '"' .. esc(v) .. '"'
      end
      parts[#parts + 1] = string.format('"%s":%s', k, vs)
    end
    table.sort(parts)
    print("{" .. table.concat(parts, ",") .. "}")
  else
    local t = ev.type or "?"
    local rest = {}
    for k, v in pairs(ev) do
      if k ~= "type" then
        rest[#rest + 1] = k .. "=" .. tostring(v)
      end
    end
    table.sort(rest)
    print(t .. "  " .. table.concat(rest, " "))
  end
end

local events = {}
local function on_trace(ev)
  events[#events + 1] = ev
  dump_ev(ev)
end

local clock = Scheduler.VirtualClock()
local ma = fx.seq({
  fx.wait(wait_s),
  Cont.unit("ok"),
})
-- opts.trace 须为 function（true 会被忽略）；亦可用 Sched.set_tracer
local flow = Sched.start_session(ma, {}, { scheduler = clock, trace = on_trace })
clock.advance(wait_s + 0.001)

if not json_mode then
  print(string.format("-- %d events, done=%s ok=%s",
    #events, tostring(flow.done), tostring(flow.result and flow.result.ok)))
end
