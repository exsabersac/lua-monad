#!/usr/bin/env lua
-- main.lua — 运行全部 fx_api 示例，或 --filter name / test（quiet）
--
-- 仓库根：
--   lua examples/fx_api/main.lua
--   lua examples/fx_api/main.lua --filter wait
--   lua examples/fx_api/main.lua test

package.path = "src/?.lua;examples/fx_api/?.lua;" .. package.path

local C = require("_common")

-- 顺序：Core → Sugar；与 README 索引一致
local ALL = {
  "wait",
  "wait_event",
  "wait_until",
  "wait_real",
  "stop_abort_fail",
  "fork_join",
  "when_all_any",
  "chan",
  "with_timeout",
  "supervise",
  "register",
  "run_trace",
  "with_resource",
  "seq",
  "lane",
  "proxy",
  "map_parallel",
  "connect_click",
}

local function parse_args(argv)
  local quiet = false
  local filter = nil
  local i = 1
  while argv and argv[i] do
    local a = argv[i]
    if a == "test" or a == "--test" or a == "--quiet" then
      quiet = true
    elseif a == "--filter" or a == "-f" then
      i = i + 1
      filter = argv[i]
    elseif a:sub(1, 9) == "--filter=" then
      filter = a:sub(10)
    elseif not a:match("^%-") then
      -- 裸名当 filter
      filter = a
    end
    i = i + 1
  end
  return quiet, filter
end

local function run_one(name, quiet)
  local mod = require(name)
  assert(type(mod) == "table" and type(mod.run) == "function",
    "fx_api." .. name .. " missing run()")
  mod.run({ quiet = quiet })
  if quiet then
    C.ok(name)
  end
end

local function main(argv)
  local quiet, filter = parse_args(argv)
  local list = ALL
  if filter and filter ~= "" then
    list = {}
    for _, name in ipairs(ALL) do
      if name == filter then
        list[#list + 1] = name
      end
    end
    -- 无精确命中时再按子串（如 stop → stop_abort_fail）
    if #list == 0 then
      for _, name in ipairs(ALL) do
        if name:find(filter, 1, true) then
          list[#list + 1] = name
        end
      end
    end
    if #list == 0 then
      io.stderr:write("no fx_api example matched filter: " .. tostring(filter) .. "\n")
      os.exit(1)
    end
  end

  if not quiet then
    print("======== fx_api examples ========")
    print(string.format("  count=%d filter=%s", #list, tostring(filter or "*")))
    print("")
  end

  local failed = 0
  for _, name in ipairs(list) do
    local ok, err = pcall(run_one, name, quiet)
    if not ok then
      failed = failed + 1
      io.stderr:write(string.format("FAIL fx_api/%s: %s\n", name, tostring(err)))
    end
  end

  if not quiet then
    print("")
    print(string.format("======== done: %d ok, %d fail ========", #list - failed, failed))
  end

  if failed > 0 then
    os.exit(1)
  end
  if quiet then
    print("fx_api all OK")
  end
end

-- 供 tests/run.lua require
local export = { ALL = ALL, run_one = run_one, main = main }

if arg and arg[0] and tostring(arg[0]):match("main%.lua") then
  main(arg)
end

return export
