#!/usr/bin/env lua
-- flow_doctor.lua — 检查常见 fx / session 误配置（CI 友好）
-- 在仓库根目录：
--   lua5.3 tools/flow_doctor.lua
--   lua5.3 tools/flow_doctor.lua --strict
--   lua5.3 tools/flow_doctor.lua --kinds
-- 详见 tools/README.md

package.path = "src/?.lua;" .. package.path

local Coro = require("coro")
local fx = require("fx")
local Registry = require("fx_registry")

------------------------------------------------------------
-- CLI
------------------------------------------------------------

local FLAG_STRICT = "--" .. "str" .. "ict"

local function usage()
  print(string.format([[flow_doctor — 检查常见 Cont/fx 误配置

用法:
  lua5.3 tools/flow_doctor.lua [选项]

选项:
  %%s           CI 模式：任一项硬检查失败则 exit 1
  --kinds         仅打印 STANDARD_KINDS 列表后退出
  --help, -h      本说明

检查项:
  1) 未知 yield kind → 期望 Failed{tag=unknown_effect}
  2) wait 无 scheduler → 提示 busy_wait（工程应注入 opts.scheduler）
  3) 打印 fx_registry.STANDARD_KINDS
]], FLAG_STRICT))
end

local strict_mode = false
local kinds_only = false
do
  local args = arg or {}
  local i = 1
  while i <= #args do
    local a = args[i]
    if a == "--help" or a == "-h" then
      usage()
      os.exit(0)
    elseif a == FLAG_STRICT or a == "--ci" then
      strict_mode = true
    elseif a == "--kinds" then
      kinds_only = true
    else
      io.stderr:write("unknown arg: " .. tostring(a) .. " (try --help)\n")
      os.exit(2)
    end
    i = i + 1
  end
end

------------------------------------------------------------
-- helpers
------------------------------------------------------------

local failures = 0
local warnings = 0

local function ok(msg)
  print("[OK]   " .. msg)
end

local function fail(msg)
  failures = failures + 1
  print("[FAIL] " .. msg)
end

local function warn(msg)
  warnings = warnings + 1
  print("[WARN] " .. msg)
end

local function info(msg)
  print("[INFO] " .. msg)
end

local function list_standard_kinds()
  local names = {}
  for k in pairs(Registry.STANDARD_KINDS) do
    names[#names + 1] = k
  end
  table.sort(names)
  print("STANDARD_KINDS (" .. #names .. "):")
  for _, k in ipairs(names) do
    local meta = Registry.STANDARD_KINDS[k]
    local role = meta and meta.role or "?"
    local desc = meta and meta.desc or ""
    if #desc > 72 then
      desc = desc:sub(1, 69) .. "..."
    end
    print(string.format("  %-16s  [%s] %s", k, role, desc))
  end
  return names
end

if kinds_only then
  list_standard_kinds()
  os.exit(0)
end

print(string.format("flow_doctor  Lua %s  %s=%s", _VERSION, FLAG_STRICT, tostring(strict_mode)))
print("")

------------------------------------------------------------
-- 1) unknown kind → Failed
------------------------------------------------------------

do
  info("check: unknown yield kind → Failed")
  local kind = "__flow_doctor_unknown_kind__"
  local r = fx.run(Coro.yield({ kind = kind }))
  if not r.failed then
    fail("expected Failed for unknown kind, got ok=" .. tostring(r.ok))
  elseif type(r.error) ~= "table" then
    fail("expected error table, got " .. type(r.error))
  elseif r.error.tag ~= "unknown_effect" then
    fail("expected tag=unknown_effect, got " .. tostring(r.error.tag))
  elseif r.error.effect_kind ~= kind then
    fail("expected effect_kind=" .. kind .. ", got " .. tostring(r.error.effect_kind))
  else
    ok(string.format("unknown kind → Failed{tag=%s, effect_kind=%s}",
      r.error.tag, tostring(r.error.effect_kind)))
  end
end

------------------------------------------------------------
-- 2) wait without scheduler（常见工程误配置）
------------------------------------------------------------

do
  info("check: wait without opts.scheduler")
  -- 无 scheduler 时走 busy_wait / 演示路径；游戏逻辑应注入 VirtualClock/GameSim/Unity scheduler。
  local r = fx.run(fx.wait(0), {})
  if not r.ok then
    fail("wait(0) without scheduler unexpectedly failed: " .. tostring(r.error))
  else
    warn("wait 无 opts.scheduler → busy_wait / 演示路径（工程请注入 scheduler；见 docs/Unity对接.md）")
    ok("wait(0) without scheduler still completes (demo path)")
  end
end

------------------------------------------------------------
-- 3) STANDARD_KINDS
------------------------------------------------------------

print("")
local names = list_standard_kinds()
if #names < 8 then
  fail("STANDARD_KINDS suspiciously small: " .. #names)
else
  ok("STANDARD_KINDS listed (" .. #names .. " kinds)")
end

local required = {
  "wait", "wait_until", "chan_send", "chan_recv", "supervise",
  "lane", "lane_join", "proxy_join", "when_all",
}
local missing = {}
for _, k in ipairs(required) do
  if Registry.STANDARD_KINDS[k] == nil then
    missing[#missing + 1] = k
    fail("missing STANDARD_KINDS." .. k)
  end
end
if #missing == 0 then
  ok("required kinds present: " .. table.concat(required, ", "))
end

------------------------------------------------------------
-- summary
------------------------------------------------------------

print("")
print(string.format("summary: failures=%d warnings=%d", failures, warnings))
if strict_mode and failures > 0 then
  print("flow_doctor: CI FAIL")
  os.exit(1)
end
print("flow_doctor: OK")
os.exit(0)
