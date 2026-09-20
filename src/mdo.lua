-- mdo.lua — Haskell 风格 do-notation 预处理器（库）
--
-- 将 `@mdo MONAD ... @end` 块展开为 `>>` / `..` 嵌套调用，
-- 让长绑定链可读。不是运行时 DSL，而是真正的源码变换。
--
-- 主要 API：
--   mdo.expand(body_src, monad)  — 展开 do 正文为 Lua 表达式字符串
--   mdo.preprocess(file_src)     — 处理整文件，替换所有 @mdo 块
--
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

return M
