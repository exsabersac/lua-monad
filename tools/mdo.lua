#!/usr/bin/env lua
-- tools/mdo.lua — do-notation 预处理器 CLI
--
-- 用法：
--   lua tools/mdo.lua INPUT.mdo [-o OUTPUT.lua]   — 预处理并写 .lua（默认）
--   lua tools/mdo.lua --run INPUT.mdo [args...]   — 内存预处理后执行
--   lua tools/mdo.lua -e INPUT.mdo [args...]      — --run 的别名
--
-- 在仓库根目录执行。--run 时会设置 package.path 含 src/?.lua，
-- 并调用 mdo.install_loader()，再 mdo.dofile(input, ...)。

local function script_dir()
  local src = debug.getinfo(1, "S").source
  if src:sub(1, 1) == "@" then
    local path = src:sub(2)
    return path:match("^(.*)/[^/]+$") or "."
  end
  return "."
end

local root = script_dir() .. "/.."
package.path = root .. "/src/?.lua;" .. package.path

local mdo = require("mdo")

local function usage()
  io.stderr:write([[用法:
  lua tools/mdo.lua INPUT.mdo [-o OUTPUT.lua]
  lua tools/mdo.lua --run|-e INPUT.mdo [args...]
]])
  os.exit(2)
end

local args = { ... }
if #args < 1 then
  usage()
end

local mode = "compile" -- or "run"
local input = nil
local output = nil
local run_args = {}

local i = 1
while i <= #args do
  local a = args[i]
  if a == "--run" or a == "-e" then
    mode = "run"
    i = i + 1
    if not args[i] then
      usage()
    end
    input = args[i]
    i = i + 1
    while i <= #args do
      run_args[#run_args + 1] = args[i]
      i = i + 1
    end
  elseif a == "-o" then
    output = args[i + 1]
    if not output then
      usage()
    end
    i = i + 2
  elseif a:sub(1, 1) == "-" then
    io.stderr:write("未知参数: " .. tostring(a) .. "\n")
    usage()
  else
    if input then
      io.stderr:write("多余参数: " .. tostring(a) .. "\n")
      usage()
    end
    input = a
    i = i + 1
  end
end

if not input then
  usage()
end

if mode == "run" then
  mdo.install_loader()
  local ok, err = pcall(function()
    mdo.dofile(input, table.unpack(run_args))
  end)
  if not ok then
    io.stderr:write(tostring(err) .. "\n")
    os.exit(1)
  end
  os.exit(0)
end

-- compile mode
if not output then
  if input:match("%.mdo$") then
    output = input:gsub("%.mdo$", ".lua")
  else
    output = input .. ".lua"
  end
end

local f, err = io.open(input, "r")
if not f then
  io.stderr:write("无法读取 " .. input .. ": " .. tostring(err) .. "\n")
  os.exit(1)
end
local src = f:read("*a")
f:close()

local ok, result = pcall(mdo.preprocess, src)
if not ok then
  io.stderr:write(tostring(result) .. "\n")
  os.exit(1)
end

local out, oerr = io.open(output, "w")
if not out then
  io.stderr:write("无法写入 " .. output .. ": " .. tostring(oerr) .. "\n")
  os.exit(1)
end
out:write(result)
if result:sub(-1) ~= "\n" then
  out:write("\n")
end
out:close()

io.stdout:write(string.format("已生成: %s\n", output))
