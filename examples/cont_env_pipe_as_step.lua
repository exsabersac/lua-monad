#!/usr/bin/env lua
-- cont_env_pipe_as_step.lua — 整条 withEnv 管道当作另一条 withEnv 的一步
-- 在仓库根目录执行：lua examples/cont_env_pipe_as_step.lua
--
-- 这是最干净的「CPS 调 CPS」故事：inner 是 a→Cont；outer 的 mid 步 return inner(x)。

package.path = "src/?.lua;" .. package.path

local Cont = require("cont")
local print, assert = print, assert

-- 内层管道：加倍再加一
local inner = Cont.withEnv(function(_ENV)
  function double(x)
    print("    [inner.double]", x, "→", x * 2)
    return Cont.unit(x * 2)
  end
  function add1(x)
    print("    [inner.add1]", x, "→", x + 1)
    return Cont.unit(x + 1)
  end
end)

-- 外层：before → mid(=inner) → after
local outer = Cont.withEnv(function(_ENV)
  function before(x)
    print("  [outer.before] 入站", x)
    return Cont.unit(x)
  end

  -- mid 是一步；返回值是 inner 管道产生的 Cont
  function mid(x)
    print("  [outer.mid] 转入 inner 管道")
    return inner(x)
  end

  function after(x)
    local tagged = { value = x, via = "outer" }
    print("  [outer.after] 出站", x)
    return Cont.unit(tagged)
  end
end)

print("=== outer(5)：before → inner(double→add1) → after ===")
local r = Cont.evalCont(outer(5))
print("结果 value=", r.value, "via=", r.via)
-- 5 → double 10 → add1 11 → {value=11, via="outer"}
assert(r.value == 11 and r.via == "outer")

print("\n=== 单独跑 inner 对照 ===")
assert(Cont.evalCont(inner(5)) == 11)
print("inner(5) =", Cont.evalCont(inner(5)))

print("\n=== 嵌套再一层：outer 本身再被包进更外层 ===")
local wrap = Cont.withEnv(function(_ENV)
  function preface(x)
    print(" [wrap.preface]", x)
    return Cont.unit(x + 0) -- 恒等，仅占位日志
  end
  function body(x)
    return outer(x) -- 整段 outer 当一步
  end
end)
local w = Cont.evalCont(wrap(5))
assert(w.value == 11)
print("wrap→outer→inner 仍得", w.value)

print("cont_env_pipe_as_step OK")
