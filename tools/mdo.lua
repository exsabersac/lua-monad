#!/usr/bin/env lua
-- tools/mdo.lua — do-notation 预处理器 CLI
--
-- 用法：
--   lua tools/mdo.lua INPUT.mdo [-o OUTPUT.lua]
-- 默认输出：与输入同路径，扩展名改为 .lua
--
-- 在仓库根目录执行。

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
  io.stderr:write("用法: lua tools/mdo.lua INPUT.mdo [-o OUTPUT.lua]\n")
  os.exit(2)
end

local args = { ... }
if #args < 1 then
  usage()
end

local input = args[1]
local output = nil
local i = 2
while i <= #args do
  if args[i] == "-o" then
    output = args[i + 1]
    if not output then
      usage()
    end
    i = i + 2
  else
    io.stderr:write("未知参数: " .. tostring(args[i]) .. "\n")
    usage()
  end
end

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
