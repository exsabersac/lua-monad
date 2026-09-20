#!/usr/bin/env lua
-- cont_env_attrs_helper.lua — __Helper__ / __NotStep__：挂在 env 上但不进管道
-- 在仓库根目录执行：lua examples/cont_env_attrs_helper.lua
--
-- 对比：未标注的 function 会成为 >> 步骤；__Helper__() 后再赋函数则只存取、不参与管道。

package.path = "src/?.lua;" .. package.path

local Cont = require("cont")
local print, assert, tostring = print, assert, tostring

print("=== 误挂助手（无属性）→ 多出一个步骤 ===")
local accidental = Cont.withEnv(function(_ENV)
  function bump(x)
    print("  [bump 被当成步骤]", x)
    return Cont.unit(x + 100)
  end
  function main(x)
    print("  [main]", x)
    return Cont.unit(x * 2)
  end
end)
-- bump → main：3 → 103 → 206
local a = Cont.evalCont(accidental(3))
print("结果:", a)
assert(a == 206)

print("\n=== __Helper__：助手可读，但不进 >> ===")
local good = Cont.withEnv(function(_ENV)
  __Helper__()
  function bump(x)
    -- 仅供 main 调用；不会单独作为管道步骤执行
    print("  [bump 仅被 main 调用]", x)
    return Cont.unit(x + 100)
  end

  function main(x)
    print("  [main] 调用 bump", x)
    return bump(x) >> function(y)
      return Cont.unit(y * 2)
    end
  end
end)
-- 只有 main：3 → bump 103 → *2 → 206；但管道长度 1
local g = Cont.evalCont(good(3))
print("结果:", g)
assert(g == 206)

print("\n=== __NotStep__ 别名 + 多步骤管道 ===")
local pipe = Cont.withEnv(function(_ENV)
  __NotStep__()
  function double(x)
    return Cont.unit(x * 2)
  end

  function add1(x)
    return Cont.unit(x + 1)
  end

  function times3(x)
    -- 步内用助手
    return double(x) >> function(y)
      return Cont.unit(y * 3)
    end
  end
end)
-- 管道：add1 → times3；输入 2 → 3 → double 6 → *3 → 18
local p = Cont.evalCont(pipe(2))
print("add1→times3(用 double 助手):", p)
assert(p == 18)

print("\ncont_env_attrs_helper OK")
