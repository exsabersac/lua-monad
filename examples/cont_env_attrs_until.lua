#!/usr/bin/env lua
-- cont_env_attrs_until.lua — __Until__(pred[, max])：结果不满足谓词则再喂回步骤
-- 在仓库根目录执行：lua examples/cont_env_attrs_until.lua

package.path = "src/?.lua;" .. package.path

local Cont = require("cont")
local print, assert, tostring = print, assert, tostring

print("=== __Until__：每次 +3，直到 >= 10 ===")
local grow = Cont.withEnv(function(_ENV)
  __Until__(function(a)
    return a >= 10
  end)
  function grow3(x)
    local n = x + 3
    print("  [grow3]", x, "→", n)
    return Cont.unit(n)
  end
end)

-- 1 → 4 → 7 → 10（停）
local v = Cont.evalCont(grow(1))
print("结果:", v)
assert(v == 10)

print("\n=== __Until__ 接在管道前/后其他步骤 ===")
local pipe = Cont.withEnv(function(_ENV)
  function start(x)
    print("  [start]", x)
    return Cont.unit(x)
  end

  __Until__(function(a)
    return a >= 10
  end, 100)
  function grow3(x)
    return Cont.unit(x + 3)
  end

  function tag(x)
    return Cont.unit({ n = x, ok = true })
  end
end)

local t = Cont.evalCont(pipe(1))
print("结果 n=", t.n, "ok=", t.ok)
assert(t.n == 10 and t.ok == true)

print("\ncont_env_attrs_until OK")
