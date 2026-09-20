#!/usr/bin/env lua
-- cont_env_mutual_pipes.lua — 多条 Cont.withEnv 管道互调 / 分层组合
-- 在仓库根目录执行：lua examples/cont_env_mutual_pipes.lua
--
-- 要点：withEnv 的返回值是 a → Cont r b；管道之间用 >> 或「步内 return other(x)」互调。
-- 分层：outer → format → core → prep；避免环状无限递归。

package.path = "src/?.lua;" .. package.path

local Cont = require("cont")
local print, assert, tostring, type, tonumber = print, assert, tostring, type, tonumber

-- ---------- 内层：prep（规范化 / 轻量预处理）----------
local prep = Cont.withEnv(function(_ENV)
  function coerce(x)
    -- 数字原样；字符串尝试 tonumber
    if type(x) == "number" then
      print("  [prep.coerce] 数字", x)
      return Cont.unit(x)
    end
    local n = tonumber(x)
    print("  [prep.coerce] 字符串", tostring(x), "→", n)
    return Cont.unit(n)
  end

  function ensure_positive(n)
    if n == nil or n <= 0 then
      print("  [prep.ensure_positive] 非法，改成 1")
      return Cont.unit(1)
    end
    print("  [prep.ensure_positive] 通过", n)
    return Cont.unit(n)
  end
end)

-- ---------- 中层：core（业务；步内调用 prep）----------
local core = Cont.withEnv(function(_ENV)
  -- 第一步：把输入交给 prep 管道，再绑定结果
  function ingest(x)
    print("  [core.ingest] 调用 prep(", tostring(x), ")")
    -- prep(x) 返回 Cont；用 >> 接续（或直接 return prep(x)）
    return prep(x) >> function(y)
      print("  [core.ingest] prep 得", y)
      return Cont.unit(y)
    end
  end

  function square(n)
    local out = n * n
    print("  [core.square]", n, "→", out)
    return Cont.unit(out)
  end

  -- 可选：步内再调一个「小 Cont 助手」（非完整 withEnv）
  function bump(n)
    local function add_ten(k)
      return Cont.unit(k + 10)
    end
    print("  [core.bump] 经小助手 +10")
    return add_ten(n)
  end
end)

-- ---------- 外层：format（展示；整步返回 core 管道）----------
local format = Cont.withEnv(function(_ENV)
  function run_core(x)
    print("  [format.run_core] 整段交给 core")
    -- 外层一步 = 另一条管道：return other_pipe(v)
    return core(x)
  end

  function label(v)
    local s = "result=" .. tostring(v)
    print("  [format.label]", s)
    return Cont.unit(s)
  end
end)

print("=== 分层：format → core → prep；输入 \"4\" ===")
local r1 = Cont.evalCont(format("4"))
print("evalCont:", r1)
-- prep: "4"→4 → ensure 4；core: square 16 → bump 26；format: "result=26"
assert(r1 == "result=26")

print("\n=== 直接跑 core（跳过 format）；输入 3 ===")
local r2 = Cont.evalCont(core(3))
print("evalCont:", r2)
assert(r2 == 19) -- 3²=9 +10 = 19

print("\n=== 手动 >> 组合两条管道（无需第三层 withEnv）===")
-- composed pipes 就是函数：prep >> 某步；或 pipeA(x) >> 后续
local manual = function(x)
  return prep(x) >> function(n)
    return Cont.unit(n * 100)
  end
end
local r3 = Cont.evalCont(manual("5"))
print("prep 再 *100:", r3)
assert(r3 == 500)

print("cont_env_mutual_pipes OK")
