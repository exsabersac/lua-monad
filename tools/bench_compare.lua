#!/usr/bin/env lua
-- bench_compare.lua — 跑当前 bench --json，可选对照 baseline，打印 Δ%
-- 在仓库根目录：
--   lua5.3 tools/bench_compare.lua
--   lua5.3 tools/bench_compare.lua --write-baseline
--   lua5.3 tools/bench_compare.lua --ci
--   lua5.3 tools/bench_compare.lua --baseline tools/bench_baseline.json --threshold 0.25
-- 详见 tools/README.md、docs/性能与工具.md

local DEFAULT_BASELINE = "tools/bench_baseline.json"
local DEFAULT_THRESHOLD = 0.25 -- 25% slower = regression
-- CI 默认关注的关键用例（名称精确匹配）
local CRITICAL = {
  ["Cont >> chain"] = true,
  ["fx.seq×3 run"] = true,
  ["fx.seq×3 eval"] = true,
}

------------------------------------------------------------
-- CLI
------------------------------------------------------------

local function usage()
  print([[bench_compare — 当前 bench 对照 baseline / 写 baseline / CI 回归

用法:
  lua5.3 tools/bench_compare.lua [选项] [N]

选项:
  --write-baseline       跑 bench --json 后写入 baseline 文件（默认 tools/bench_baseline.json）
  --baseline PATH        baseline 路径（默认 tools/bench_baseline.json）
  --threshold F          回归阈值：当前 sec 相对 baseline 增幅 > F 则失败（默认 0.25 = 25%）
  --ci                   CI 模式：无 baseline 或关键用例回归超阈值 → exit 1
  --filter NAME          转发给 bench_cont_fx
  --all                  CI 时对所有有 baseline 的用例检查（不仅关键项）
  --help, -h             本说明

说明:
  - 内部调用：lua5.3 tools/bench_cont_fx.lua --json [N] [--filter …]
  - 比较字段：sec（越低越好）；同时打印 rate / kb_delta 的 Δ%
  - --ci 默认只对 Cont >> chain / fx.seq×3 run / fx.seq×3 eval 判回归；--all 则全量
]])
end

local write_baseline = false
local baseline_path = DEFAULT_BASELINE
local threshold = DEFAULT_THRESHOLD
local ci_mode = false
local filter = nil
local check_all = false
local N = nil

do
  local args = arg or {}
  local i = 1
  while i <= #args do
    local a = args[i]
    if a == "--help" or a == "-h" then
      usage()
      os.exit(0)
    elseif a == "--write-baseline" then
      write_baseline = true
    elseif a == "--ci" then
      ci_mode = true
    elseif a == "--all" then
      check_all = true
    elseif a:sub(1, 12) == "--baseline=" then
      baseline_path = a:sub(13)
    elseif a == "--baseline" then
      i = i + 1
      baseline_path = args[i]
    elseif a:sub(1, 12) == "--threshold=" then
      threshold = tonumber(a:sub(13))
    elseif a == "--threshold" then
      i = i + 1
      threshold = tonumber(args[i])
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

if not threshold or threshold < 0 then
  io.stderr:write("--threshold must be a non-negative number\n")
  os.exit(2)
end

------------------------------------------------------------
-- JSON helpers（极简 NDJSON：每行一个对象，只用到的字段）
------------------------------------------------------------

local function esc_json(s)
  s = tostring(s)
  return (s:gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\n", "\\n"))
end

local function parse_json_obj(line)
  -- 仅解析本仓库 bench 产出的扁平数字/字符串字段
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
  obj.dkb = kb
  local note = line:match('"note"%s*:%s*"([^"]*)"')
  if note then
    obj.note = note
  end
  return obj
end

local function read_baseline(path)
  local f = io.open(path, "r")
  if not f then
    return nil, "cannot open " .. path
  end
  local body = f:read("*a")
  f:close()
  local by_name = {}
  local meta = {}
  -- 支持两种格式：
  -- 1) NDJSON（每行一个 case）
  -- 2) 包装对象：{"meta":{...},"cases":[{...},...]}（每 case 一行写出）
  -- 逐行解析含 "name" 的对象，避免 %b{} 吃掉整份嵌套 JSON。
  meta.lua = body:match('"lua"%s*:%s*"([^"]*)"')
  meta.n_default = tonumber(body:match('"n_default"%s*:%s*([%-%d%.eE]+)'))
  meta.created = body:match('"created"%s*:%s*"([^"]*)"')
  meta.host = body:match('"host"%s*:%s*"([^"]*)"')
  for line in body:gmatch("[^\r\n]+") do
    line = line:match("^%s*(.-)%s*$") or line
    if line ~= "" and line:sub(1, 1) ~= "#" and line:find('"name"%s*:') then
      -- 去掉行尾逗号，便于 parse
      local cleaned = line:gsub(",%s*$", "")
      local o = parse_json_obj(cleaned)
      if o and o.name and o.sec then
        by_name[o.name] = o
      end
    end
  end
  return { meta = meta, by_name = by_name }
end

local function write_baseline_file(path, cases, meta)
  local f, err = io.open(path, "w")
  if not f then
    io.stderr:write("write baseline failed: " .. tostring(err) .. "\n")
    os.exit(1)
  end
  f:write("{\n")
  f:write('  "meta": {\n')
  f:write(string.format('    "lua": "%s",\n', esc_json(meta.lua or _VERSION)))
  f:write(string.format('    "n_default": %d,\n', meta.n_default or 20000))
  f:write(string.format('    "created": "%s",\n', esc_json(meta.created or "")))
  f:write(string.format('    "host": "%s",\n', esc_json(meta.host or "")))
  f:write(string.format('    "tool": "tools/bench_compare.lua --write-baseline"\n'))
  f:write("  },\n")
  f:write('  "cases": [\n')
  for i, c in ipairs(cases) do
    local comma = (i < #cases) and "," or ""
    local note = ""
    if c.note then
      note = string.format(',"note":"%s"', esc_json(c.note))
    end
    f:write(string.format(
      '    {"name":"%s","n":%d,"sec":%.6f,"rate":%.3f,"dkb":%.3f,"kb_delta":%.3f%s}%s\n',
      esc_json(c.name), c.n, c.sec, c.rate, c.kb_delta or c.dkb or 0,
      c.kb_delta or c.dkb or 0, note, comma
    ))
  end
  f:write("  ]\n")
  f:write("}\n")
  f:close()
end

------------------------------------------------------------
-- Run bench
------------------------------------------------------------

local function find_lua()
  -- 优先 PATH 中的 lua5.3
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
  -- 引号保护 filter
  local parts = {}
  for _, p in ipairs(cmd) do
    if p:find("[%s\"']") then
      parts[#parts + 1] = '"' .. p:gsub('"', '\\"') .. '"'
    else
      parts[#parts + 1] = p
    end
  end
  local line = table.concat(parts, " ")
  local h, err = io.popen(line, "r")
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
  local cases = {}
  for l in (out or ""):gmatch("[^\r\n]+") do
    local o = parse_json_obj(l)
    if o then
      cases[#cases + 1] = o
    end
  end
  if #cases == 0 then
    io.stderr:write("bench produced no JSON cases\n")
    io.stderr:write(out or "")
    os.exit(1)
  end
  return cases
end

local function pct_delta(cur, base)
  if not base or base == 0 then
    return nil
  end
  return (cur - base) / base * 100
end

local function fmt_pct(p)
  if p == nil then
    return "n/a"
  end
  local sign = p >= 0 and "+" or ""
  return string.format("%s%.1f%%", sign, p)
end

------------------------------------------------------------
-- Main
------------------------------------------------------------

local cases = run_bench()

local function iso_now()
  -- UTC-ish wall clock; box is Asia/Shanghai but baseline stamp is informational
  return os.date("!%Y-%m-%dT%H:%M:%SZ")
end

local function hostname()
  local h = io.popen("uname -n 2>/dev/null")
  if h then
    local n = h:read("*l")
    h:close()
    return n or "unknown"
  end
  return "unknown"
end

if write_baseline then
  write_baseline_file(baseline_path, cases, {
    lua = _VERSION,
    n_default = N or 20000,
    created = iso_now(),
    host = hostname(),
  })
  print(string.format("wrote baseline %s  (%d cases)", baseline_path, #cases))
  -- 仍打印当前结果摘要
end

local baseline = read_baseline(baseline_path)
if not baseline then
  if ci_mode and not write_baseline then
    io.stderr:write(string.format(
      "[CI] missing baseline: %s\n  generate with: lua5.3 tools/bench_compare.lua --write-baseline\n",
      baseline_path
    ))
    os.exit(1)
  end
  if not write_baseline then
    print(string.format("no baseline at %s — current results only (use --write-baseline to seed)", baseline_path))
  end
end

print(string.format(
  "bench_compare  threshold=%.0f%%  baseline=%s  ci=%s",
  threshold * 100, baseline_path, ci_mode and "yes" or "no"
))
print(string.format(
  "%-22s %8s %8s %10s %10s %10s %8s",
  "name", "sec", "base", "Δsec%", "Δrate%", "Δkb%", "flag"
))

local regressions = 0
local compared = 0

for _, c in ipairs(cases) do
  local b = baseline and baseline.by_name[c.name] or nil
  local dsec = b and pct_delta(c.sec, b.sec) or nil
  local drate = b and pct_delta(c.rate, b.rate) or nil
  local dkb = b and pct_delta(c.kb_delta or 0, b.kb_delta or b.dkb or 0) or nil
  local flag = ""
  local is_critical = CRITICAL[c.name] == true
  local should_check = ci_mode and b and (check_all or is_critical)
  -- regression: slower = sec increased beyond threshold
  if should_check and dsec and dsec > threshold * 100 then
    flag = "REGRESS"
    regressions = regressions + 1
  elseif b and dsec and dsec < -(threshold * 100) then
    flag = "faster"
  elseif b then
    flag = "ok"
  else
    flag = "new"
  end
  if b then
    compared = compared + 1
    if b.n and c.n and b.n ~= c.n then
      flag = flag .. "!N"
    end
  end
  local base_sec_s = (b and b.sec) and string.format("%.4f", b.sec) or "-"
  print(string.format(
    "%-22s %8.4f %8s %10s %10s %10s %8s",
    c.name,
    c.sec or 0,
    base_sec_s,
    fmt_pct(dsec),
    fmt_pct(drate),
    fmt_pct(dkb),
    flag
  ))
end

print(string.format("compared %d / %d cases; regressions=%d", compared, #cases, regressions))

if ci_mode and regressions > 0 then
  io.stderr:write(string.format(
    "[CI] %d regression(s) over %.0f%% slower threshold (Cont >> / fx.seq sync path)\n",
    regressions, threshold * 100
  ))
  os.exit(1)
end

os.exit(0)
