-- mdo.lua — Haskell 风格 do-notation 预处理器（库）
--
-- 将 `@mdo MONAD ... @end` 块展开为 `>>` / `..` 嵌套调用，
-- 让长绑定链可读。不是运行时 DSL，而是真正的源码变换。
--
-- 主要 API：
--   mdo.expand(body_src, monad)  — 展开 do 正文为 Lua 表达式字符串
--   mdo.preprocess(file_src)     — 处理整文件，替换所有 @mdo 块
--   mdo.compile(src, chunkname?) — 预处理后 load，返回 function 或 nil,err
--   mdo.loadfile(path)           — 读文件并 compile（chunkname=@path [mdo]）
--   mdo.dofile(path, ...)        — loadfile + 调用（同 Lua dofile 传参）
--   mdo.require_searcher(modname)— package 搜索器（.mdo）
--   mdo.install_loader()         — 幂等插入 package.searchers/loaders
--
-- 可选：环境变量 MDO_CACHE=1 时，mdo.dofile 会写同路径旁路 .lua 缓存（默认关闭）。
-- 语法与限制见 docs/do语法.md。

local M = {}

------------------------------------------------------------
-- 工具
------------------------------------------------------------

local function trim(s)
  return (s:match("^%s*(.-)%s*$"))
end

-- 去掉行尾 `--` 注释（不处理字符串内的 --；EXPR 应避免同行字符串含 --）
local function strip_line_comment(s)
  local out = {}
  local i = 1
  local n = #s
  local in_sq, in_dq = false, false
  while i <= n do
    local c = s:sub(i, i)
    if in_sq then
      out[#out + 1] = c
      if c == "\\" and i < n then
        out[#out + 1] = s:sub(i + 1, i + 1)
        i = i + 2
      elseif c == "'" then
        in_sq = false
        i = i + 1
      else
        i = i + 1
      end
    elseif in_dq then
      out[#out + 1] = c
      if c == "\\" and i < n then
        out[#out + 1] = s:sub(i + 1, i + 1)
        i = i + 2
      elseif c == '"' then
        in_dq = false
        i = i + 1
      else
        i = i + 1
      end
    else
      if c == "-" and s:sub(i + 1, i + 1) == "-" then
        break -- 行注释开始
      elseif c == "'" then
        in_sq = true
        out[#out + 1] = c
        i = i + 1
      elseif c == '"' then
        in_dq = true
        out[#out + 1] = c
        i = i + 1
      else
        out[#out + 1] = c
        i = i + 1
      end
    end
  end
  return trim(table.concat(out))
end

-- Lua 标识符（含 _）
local function is_ident(name)
  return type(name) == "string" and name:match("^[_%a][_%w]*$") ~= nil
end

-- 带行号的错误
local function parse_error(lineno, msg)
  error(string.format("mdo: 第 %d 行: %s", lineno, msg), 0)
end

------------------------------------------------------------
-- 解析 do 正文 → 语句列表
-- 每条: { kind = "bind"|"let"|"seq", name?, expr, line }
------------------------------------------------------------

local function parse_body(body_src, base_line)
  base_line = base_line or 1
  local stmts = {}
  local line_no = base_line - 1
  for line in (body_src .. "\n"):gmatch("(.-)\n") do
    line_no = line_no + 1
    local raw = line
    local t = strip_line_comment(raw)
    if t == "" then
      -- 空行 / 纯注释：跳过
    elseif t:match("^@mdo") then
      parse_error(line_no, "暂不支持嵌套 @mdo")
    elseif t:match("^@end") then
      parse_error(line_no, "意外的 @end（应由 preprocess 消费）")
    else
      -- let NAME = EXPR
      local let_name, let_expr = t:match("^let%s+([_%a][_%w]*)%s*=%s*(.+)$")
      if let_name then
        if not is_ident(let_name) then
          parse_error(line_no, "let 绑定名非法: " .. tostring(let_name))
        end
        let_expr = trim(let_expr)
        if let_expr == "" then
          parse_error(line_no, "let 缺少表达式")
        end
        stmts[#stmts + 1] = { kind = "let", name = let_name, expr = let_expr, line = line_no }
      else
        -- NAME <- EXPR（NAME 为标识符，含 _）
        local bname, bexpr = t:match("^([_%a][_%w]*)%s*<%-%s*(.+)$")
        if bname then
          if not is_ident(bname) then
            parse_error(line_no, "绑定名非法: " .. tostring(bname))
          end
          bexpr = trim(bexpr)
          if bexpr == "" then
            parse_error(line_no, "绑定缺少表达式")
          end
          stmts[#stmts + 1] = { kind = "bind", name = bname, expr = bexpr, line = line_no }
        else
          -- 裸 EXPR
          stmts[#stmts + 1] = { kind = "seq", expr = t, line = line_no }
        end
      end
    end
  end
  return stmts
end

------------------------------------------------------------
-- 语句列表 → Lua 表达式（自尾向前展开）
------------------------------------------------------------

local function compile_stmts(stmts, idx)
  if idx > #stmts then
    error("mdo: do 块为空", 0)
  end
  local s = stmts[idx]
  if idx == #stmts then
    if s.kind == "let" then
      parse_error(s.line, "do 块不能以 let 结尾")
    end
    if s.kind == "bind" then
      parse_error(s.line, "do 块最后一行须为 monadic 表达式（不能是 NAME <- EXPR）")
    end
    return s.expr
  end

  local rest = compile_stmts(stmts, idx + 1)

  if s.kind == "let" then
    return string.format(
      "(function()\nlocal %s = %s\nreturn %s\nend)()",
      s.name, s.expr, rest
    )
  elseif s.kind == "bind" then
    if s.name == "_" then
      -- _ <- ma  等价于丢弃结果的序列（Haskell >>）
      return string.format("(%s .. (%s))", s.expr, rest)
    else
      return string.format(
        "%s >> function(%s)\nreturn %s\nend",
        s.expr, s.name, rest
      )
    end
  elseif s.kind == "seq" then
    -- 中间裸表达式：ma .. (rest)
    return string.format("(%s .. (%s))", s.expr, rest)
  else
    parse_error(s.line, "未知语句种类: " .. tostring(s.kind))
  end
end

--- 展开 do 正文为 Lua 表达式字符串。
--- @param body_src string  @mdo 与 @end 之间的正文（不含标记行）
--- @param monad string     单子名前缀（目前仅作上下文/文档；展开用值上的 >> / ..）
--- @param base_line number|nil  正文首行在原文件中的行号（用于报错）
--- @return string
function M.expand(body_src, monad, base_line)
  if monad ~= nil and monad ~= "" then
    -- 校验 monad 为标识符或简单限定名（Maybe / Foo.Bar）
    if not monad:match("^[%a_][%w_]*[%.%w_]*$") then
      error("mdo: 非法的 monad 名: " .. tostring(monad), 0)
    end
  end
  local stmts = parse_body(body_src, base_line or 1)
  if #stmts == 0 then
    error("mdo: do 块为空（至少需要一条 monadic 表达式）", 0)
  end
  return compile_stmts(stmts, 1)
end

------------------------------------------------------------
-- 整文件预处理：替换 @mdo MONAD ... @end
------------------------------------------------------------

--- 预处理整段源码，将所有 `@mdo MONAD ... @end` 换成展开后的 Lua。
--- @param file_src string
--- @return string
function M.preprocess(file_src)
  local lines = {}
  for line in (file_src .. "\n"):gmatch("(.-)\n") do
    lines[#lines + 1] = line
  end

  local out = {}
  local i = 1
  while i <= #lines do
    local line = lines[i]
    -- 在行内查找 @mdo（允许前面有 local foo = 等前缀）
    local before, monad, after = line:match("^(.*)@mdo%s+([%a_][%w_%.]*)%s*(.*)$")
    if before then
      after = trim(after or "")
      if after ~= "" and not after:match("^%-%-") then
        error(string.format(
          "mdo: 第 %d 行: @mdo 后只能跟 monad 名（与可选注释），得到: %s",
          i, after
        ), 0)
      end

      -- 收集正文直到 @end
      local body_lines = {}
      local body_start = i + 1
      local j = i + 1
      local found_end = false
      local end_after = ""
      while j <= #lines do
        local L = lines[j]
        local pre, post = L:match("^(.*)@end%s*(.*)$")
        if pre and not L:match("@mdo") then
          -- @end 所在行：@end 之前若有内容并入正文
          local pre_t = trim(pre)
          if pre_t ~= "" then
            body_lines[#body_lines + 1] = pre
          end
          end_after = post or ""
          found_end = true
          break
        end
        if L:match("@mdo") then
          error(string.format("mdo: 第 %d 行: 暂不支持嵌套 @mdo", j), 0)
        end
        body_lines[#body_lines + 1] = L
        j = j + 1
      end
      if not found_end then
        error(string.format("mdo: 第 %d 行: @mdo 缺少匹配的 @end", i), 0)
      end

      local body_src = table.concat(body_lines, "\n")
      local ok, expanded = pcall(M.expand, body_src, monad, body_start)
      if not ok then
        -- expand 已带行号信息
        error(expanded, 0)
      end

      -- 前缀 + 展开式；若前缀非空，直接拼接
      local prefix = before
      if trim(prefix) ~= "" then
        out[#out + 1] = prefix .. expanded
      else
        out[#out + 1] = expanded
      end
      -- @end 同行后缀（极少用）
      if trim(end_after) ~= "" then
        out[#out] = out[#out] .. " " .. end_after
      end

      i = j + 1
    else
      if line:match("@end") and not line:match("@mdo") then
        error(string.format("mdo: 第 %d 行: 孤立的 @end（没有对应的 @mdo）", i), 0)
      end
      out[#out + 1] = line
      i = i + 1
    end
  end

  return table.concat(out, "\n")
end

------------------------------------------------------------
-- 加载 / 执行 / package 搜索器
------------------------------------------------------------

-- 去掉 shebang，便于 load
local function strip_shebang(s)
  if s:sub(1, 2) == "#!" then
    local nl = s:find("\n", 1, true)
    if nl then
      return s:sub(nl + 1)
    end
    return ""
  end
  return s
end

local function read_file(path)
  local f, err = io.open(path, "r")
  if not f then
    return nil, err
  end
  local data = f:read("*a")
  f:close()
  return data
end

--- 预处理源码后 `load` 为可调用 chunk。
--- @param src string           含 @mdo 的源码
--- @param chunkname string|nil load 的 chunk 名（调试用）
--- @return function|nil, string|nil  成功返回函数；失败返回 nil, err
function M.compile(src, chunkname)
  local ok, result = pcall(M.preprocess, src)
  if not ok then
    return nil, tostring(result)
  end
  local lua_src = strip_shebang(result)
  return load(lua_src, chunkname or "=(mdo)", "t")
end

--- 读取文件并编译（预处理 + load）。
--- chunkname：默认 `@path`；若扩展名为 `.mdo` 则为 `@path [mdo]`。
--- @param path string
--- @return function|nil, string|nil
function M.loadfile(path)
  local src, err = read_file(path)
  if not src then
    return nil, "cannot read " .. tostring(path) .. ": " .. tostring(err)
  end
  local chunkname
  if path:match("%.mdo$") then
    chunkname = "@" .. path .. " [mdo]"
  else
    chunkname = "@" .. path
  end
  return M.compile(src, chunkname)
end

-- 可选旁路缓存：仅当 MDO_CACHE=1 时写入同路径 .lua（默认关闭，避免意外覆盖）
local function maybe_write_cache(path, lua_src)
  if os.getenv("MDO_CACHE") ~= "1" then
    return
  end
  if not path:match("%.mdo$") then
    return
  end
  local out_path = path:gsub("%.mdo$", ".lua")
  local f = io.open(out_path, "w")
  if not f then
    return
  end
  f:write(lua_src)
  if lua_src:sub(-1) ~= "\n" then
    f:write("\n")
  end
  f:close()
end

--- 加载并执行文件，可变参数传给 chunk（行为类似 Lua `dofile`）。
--- 若环境变量 `MDO_CACHE=1`，会把预处理结果写到同目录 `.lua`（默认不写）。
--- @param path string
--- @param ... any
--- @return ... chunk 的返回值
function M.dofile(path, ...)
  local src, err = read_file(path)
  if not src then
    error("mdo.dofile: cannot read " .. tostring(path) .. ": " .. tostring(err), 0)
  end
  local chunkname
  if path:match("%.mdo$") then
    chunkname = "@" .. path .. " [mdo]"
  else
    chunkname = "@" .. path
  end
  local ok, result = pcall(M.preprocess, src)
  if not ok then
    error(tostring(result), 0)
  end
  maybe_write_cache(path, result)
  local lua_src = strip_shebang(result)
  local chunk, lerr = load(lua_src, chunkname, "t")
  if not chunk then
    error("mdo.dofile: load failed for " .. tostring(path) .. ": " .. tostring(lerr), 0)
  end
  return chunk(...)
end

-- 额外 .mdo 搜索模板（相对当前工作目录）
local EXTRA_MDO_TEMPLATES = {
  "src/?.mdo",
  "examples/?.mdo",
  "./?.mdo",
}

local function path_templates_for_mdo()
  local seen = {}
  local list = {}
  local function add(t)
    if t and t ~= "" and not seen[t] then
      seen[t] = true
      list[#list + 1] = t
    end
  end
  for template in string.gmatch(package.path, "([^;]+)") do
    add(template)
    if template:find("?.lua", 1, true) then
      add((template:gsub("%?%.lua", "?.mdo")))
    end
  end
  for _, t in ipairs(EXTRA_MDO_TEMPLATES) do
    add(t)
  end
  return list
end

local function module_to_filepath(modname, template)
  local name = modname:gsub("%.", "/")
  return (template:gsub("%?", name, 1))
end

--- package 搜索器：在 `package.path` 中把 `?.lua` 换成 `?.mdo` 尝试，
--- 并额外搜索 `src/?.mdo`、`examples/?.mdo`、`./?.mdo`。
--- 找到则返回 loader（调用后得到模块返回值）；否则返回说明字符串。
--- @param modname string
--- @return function|string
function M.require_searcher(modname)
  local tried = {}
  for _, template in ipairs(path_templates_for_mdo()) do
    -- 只尝试 .mdo 模板（由 ?.lua 派生或 EXTRA）
    if template:find("?.mdo", 1, true) or template:match("%.mdo$") then
      local filepath = module_to_filepath(modname, template)
      tried[#tried + 1] = filepath
      local f = io.open(filepath, "r")
      if f then
        f:close()
        return function()
          local chunk, err = M.loadfile(filepath)
          if not chunk then
            error(
              "error loading module '" .. modname .. "' from " .. filepath
                .. ":\n\t" .. tostring(err),
              0
            )
          end
          -- 与 Lua 标准 searcher 一致：把 modname 与路径传给 chunk
          return chunk(modname, filepath)
        end
      end
    end
  end
  return "\n\tno mdo module '" .. modname .. "'"
end

local _loader_installed = false

--- 将 `require_searcher` 插入 `package.searchers`（Lua 5.2+）或
--- `package.loaders`（Lua 5.1）。幂等：重复调用不会重复插入。
function M.install_loader()
  if _loader_installed then
    return
  end
  local searchers = package.searchers or package.loaders
  if not searchers then
    error("mdo.install_loader: 当前 Lua 无 package.searchers / package.loaders", 0)
  end
  for _, s in ipairs(searchers) do
    if s == M.require_searcher then
      _loader_installed = true
      return
    end
  end
  searchers[#searchers + 1] = M.require_searcher
  _loader_installed = true
end

return M
