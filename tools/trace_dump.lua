#!/usr/bin/env lua
-- trace_dump.lua — 把 fx/fx_sched trace 事件打印到 stdout（或 --json 一行一 JSON）
-- 用法（仓库根）：
--   lua5.3 tools/trace_dump.lua
--   lua5.3 tools/trace_dump.lua --json
--   lua5.3 tools/trace_dump.lua --wait 0.05

package.path = "src/?.lua;" .. package.path

local Cont = require("cont")
local fx = require("fx")
local Sched = require("fx_sched")
local Scheduler = require("scheduler")

local json_mode = false
local wait_s = 0.02
for _, a in ipairs(arg or {}) do
  if a == "--json" then
    json_mode = true
  elseif a:sub(1, 7) == "--wait=" then
    wait_s = tonumber(a:sub(8)) or wait_s
  elseif a == "--wait" then
    -- next?
  end
end
for i, a in ipairs(arg or {}) do
  if a == "--wait" and arg[i + 1] then
    wait_s = tonumber(arg[i + 1]) or wait_s
  end
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
      else
        vs = '"' .. esc(v) .. '"'
      end
      parts[#parts + 1] = string.format('"%s":%s', k, vs)
    end
    table.sort(parts)
    print("{" .. table.concat(parts, ",") .. "}")
  else
    local t = ev.type or "?"
    local bits = { t }
    for k, v in pairs(ev) do
      if k ~= "type" then
        bits[#bits + 1] = k .. "=" .. tostring(v)
      end
    end
    table.sort(bits)
    -- keep type first
    local rest = {}
    for _, b in ipairs(bits) do
      if b ~= t then
        rest[#rest + 1] = b
      end
    end
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
