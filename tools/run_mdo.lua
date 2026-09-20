#!/usr/bin/env lua
-- tools/run_mdo.lua — 便捷包装：直接跑 .mdo
--
--   lua tools/run_mdo.lua examples/do_maybe_foo.mdo [args...]
--
-- 等价于：lua tools/mdo.lua --run <file> [args...]

local function script_dir()
  local src = debug.getinfo(1, "S").source
  if src:sub(1, 1) == "@" then
    local path = src:sub(2)
    return path:match("^(.*)/[^/]+$") or "."
  end
  return "."
end

local here = script_dir()
local args = { ... }
if #args < 1 then
  io.stderr:write("用法: lua tools/run_mdo.lua INPUT.mdo [args...]\n")
  os.exit(2)
end

-- 转调 tools/mdo.lua --run …
local mdo_cli = here .. "/mdo.lua"
local cmd_args = { mdo_cli, "--run" }
for _, a in ipairs(args) do
  cmd_args[#cmd_args + 1] = a
end

-- 同进程执行（保留 package / 调试栈），避免 os.execute 再开一层
dofile = dofile -- keep
-- 用 loadfile 跑 CLI：CLI 读 {...}，需伪造
local chunk, err = loadfile(mdo_cli)
if not chunk then
  io.stderr:write("无法加载 " .. mdo_cli .. ": " .. tostring(err) .. "\n")
  os.exit(1)
end
-- CLI 以 `local args = { ... }` 取可变参数；直接 chunk("--run", ...)
chunk("--run", table.unpack(args))
