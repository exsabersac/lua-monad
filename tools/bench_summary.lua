#!/usr/bin/env lua
-- bench_summary.lua — 从 bench --json（或 stdin / 文件）生成 Markdown 表
-- 用法（仓库根）：
--   lua5.3 tools/bench_summary.lua                  # 跑 bench --json，打印 MD 表
--   lua5.3 tools/bench_summary.lua --out tools/bench_summary.md
--   lua5.3 tools/bench_cont_fx.lua --json | lua5.3 tools/bench_summary.lua --stdin
--   lua5.3 tools/bench_summary.lua --from /tmp/bench.ndjson --out tools/bench_summary.md
-- 详见 tools/README.md

local DEFAULT_OUT = "tools/bench_summary.md"

local function usage()
  print([[bench_summary — bench JSON → Markdown 表

用法:
  lua5.3 tools/bench_summary.lua [选项] [N]

选项:
  --out PATH       写入 Markdown 文件（默认打印到 stdout；传 --out 无 PATH 则用 tools/bench_summary.md）
  --from PATH      从已有 NDJSON 文件读取（每行一个 bench 对象）
  --stdin          从 stdin 读 NDJSON（配合 bench_cont_fx --json | …）
  --filter NAME    转发给 bench_cont_fx（仅在内部跑 bench 时）
  --help, -h       本说明

说明:
  默认内部调用：lua5.3 tools/bench_cont_fx.lua --json [N]
  表列：name | n | sec | rate | kb_delta
]])
end

local out_path = nil
local from_path = nil
local use_stdin = false
local filter = nil
local N = nil

do
  local args = arg or {}
  local i = 1
  while i <= #args do
    local a = args[i]
    if a == "--help" or a == "-h" then
      usage()
      os.exit(0)
    elseif a == "--stdin" then
      use_stdin = true
    elseif a == "--out" then
      i = i + 1
      if args[i] and not args[i]:match("^%-") then
        out_path = args[i]
      else
        out_path = DEFAULT_OUT
        if args[i] then
          i = i - 1 -- reprocess next flag
        end
      end
    elseif a:sub(1, 6) == "--out=" then
      out_path = a:sub(7)
      if out_path == "" then
        out_path = DEFAULT_OUT
      end
    elseif a == "--from" then
      i = i + 1
      from_path = args[i]
    elseif a:sub(1, 7) == "--from=" then
      from_path = a:sub(8)
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

------------------------------------------------------------
-- Parse NDJSON lines from bench_cont_fx
------------------------------------------------------------

local function parse_json_obj(line)
  local obj = {}
  local name = line:match('"name"%s*:%s*"([^"]*)"')
  if not name then
    return nil
  end
  obj.name = name
  obj.n = tonumber(line:match('"n"%s*:%s*([%-%d%.eE]+)'))
  obj.sec = tonumber(line:match('"sec"%s*:%s*([%-%d%.eE]+)'))
  obj.rate = tonumber(line:match('"rate"%s*:%s*([%-%d%.eE]+)'))
  local kb = tonumber(line:match('"kb_delta"%s*:%s*([%-%d%.eE]+)'))
  if not kb then
    kb = tonumber(line:match('"dkb"%s*:%s*([%-%d%.eE]+)'))
  end
  obj.kb_delta = kb
  local note = line:match('"note"%s*:%s*"([^"]*)"')
  if note then
    obj.note = note
  end
  return obj
end

local function parse_ndjson(text)
  local cases = {}
  for line in (text or ""):gmatch("[^\r\n]+") do
    local o = parse_json_obj(line)
    if o then
      cases[#cases + 1] = o
    end
  end
  return cases
end

local function find_lua()
  local h = io.popen("command -v lua5.3 2>/dev/null")
  if h then
    local p = h:read("*l")
    h:close()
    if p and p ~= "" then
      return p
    end
  end
  return "lua5.3"
end

local function run_bench()
  local lua = find_lua()
  local cmd = { lua, "tools/bench_cont_fx.lua", "--json" }
  if N then
    cmd[#cmd + 1] = tostring(N)
  end
  if filter then
    cmd[#cmd + 1] = "--filter"
    cmd[#cmd + 1] = filter
  end
  local parts = {}
  for _, p in ipairs(cmd) do
    if p:find("[%s\"']") then
      parts[#parts + 1] = '"' .. p:gsub('"', '\\"') .. '"'
    else
      parts[#parts + 1] = p
    end
  end
  local h, err = io.popen(table.concat(parts, " "), "r")
  if not h then
    io.stderr:write("failed to run bench: " .. tostring(err) .. "\n")
    os.exit(1)
  end
  local out = h:read("*a")
  local ok, _, code = h:close()
  if ok == false or (code and code ~= 0) then
    io.stderr:write("bench exited non-zero\n")
    io.stderr:write(out or "")
    os.exit(1)
  end
  return parse_ndjson(out)
end

local function load_cases()
  if use_stdin then
    local text = io.stdin:read("*a")
    return parse_ndjson(text)
  end
  if from_path then
    local f, err = io.open(from_path, "r")
    if not f then
      io.stderr:write("cannot open --from " .. from_path .. ": " .. tostring(err) .. "\n")
      os.exit(1)
    end
    local text = f:read("*a")
    f:close()
    return parse_ndjson(text)
  end
  return run_bench()
end

local function fmt_rate(r)
  if not r then
    return "-"
  end
  if r >= 1e6 then
    return string.format("%.2e", r)
  elseif r >= 1000 then
    return string.format("%.0f", r)
  else
    return string.format("%.1f", r)
  end
end

local function render_md(cases)
  local lines = {}
  lines[#lines + 1] = "# bench_summary"
  lines[#lines + 1] = ""
  lines[#lines + 1] = string.format("生成自 `tools/bench_summary.lua`（%s，%d 用例）。",
    _VERSION, #cases)
  lines[#lines + 1] = ""
  lines[#lines + 1] = "| name | n | sec | rate (/s) | kb_delta |"
  lines[#lines + 1] = "|------|--:|----:|----------:|---------:|"
  for _, c in ipairs(cases) do
    local note = c.note and (" _" .. c.note .. "_") or ""
    lines[#lines + 1] = string.format(
      "| %s%s | %d | %.4f | %s | %.1f |",
      c.name or "?",
      note,
      c.n or 0,
      c.sec or 0,
      fmt_rate(c.rate),
      c.kb_delta or 0
    )
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = "非严格 microbench（含 GC）。复现：`lua5.3 tools/bench_cont_fx.lua --json`。"
  lines[#lines + 1] = ""
  return table.concat(lines, "\n")
end

local cases = load_cases()
if #cases == 0 then
  io.stderr:write("bench_summary: no cases parsed\n")
  os.exit(1)
end

local md = render_md(cases)
if out_path then
  local f, err = io.open(out_path, "w")
  if not f then
    io.stderr:write("cannot write " .. out_path .. ": " .. tostring(err) .. "\n")
    os.exit(1)
  end
  f:write(md)
  if not md:match("\n$") then
    f:write("\n")
  end
  f:close()
  io.stderr:write(string.format("bench_summary: wrote %s  (%d cases)\n", out_path, #cases))
else
  io.stdout:write(md)
  if not md:match("\n$") then
    io.stdout:write("\n")
  end
end
os.exit(0)
