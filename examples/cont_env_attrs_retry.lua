#!/usr/bin/env lua
-- cont_env_attrs_retry.lua — __Retry__(n, pred)：pred(a) 为真则用原 x 重试
-- 在仓库根目录执行：lua examples/cont_env_attrs_retry.lua

package.path = "src/?.lua;" .. package.path

local Cont = require("cont")
local print, assert, tostring = print, assert, tostring

print("=== __Retry__：不稳定步，最多 5 次直到偶数 ===")
local attempts = 0
local pipe = Cont.withEnv(function(_ENV)
  __Retry__(5, function(a)
    return a % 2 ~= 0 -- 奇数则重试
  end)
  function unstable(x)
    attempts = attempts + 1
    -- 用 attempts 模拟：第 1、2 次返回奇数，第 3 次偶数
    local out = x + attempts -- 输入固定；输出随尝试次数变
    print("  [unstable] attempt", attempts, "→", out)
    return Cont.unit(out)
  end
end)

-- x=1：尝试1→2（偶，停）—— 为演示奇数重试，改输入 0：
-- 0+1=1 奇；0+2=2 偶 → 两次
attempts = 0
local v = Cont.evalCont(pipe(0))
print("结果:", v, "attempts:", attempts)
assert(v == 2 and attempts == 2)

print("\n=== __Retry__：始终失败，返回最后一次 a ===")
attempts = 0
local always_odd = Cont.withEnv(function(_ENV)
  __Retry__(3, function(a)
    return a % 2 ~= 0
  end)
  function oddish(x)
    attempts = attempts + 1
    local out = x * 2 + 1 -- 恒奇
    print("  [oddish]", attempts, "→", out)
    return Cont.unit(out)
  end
end)
local last = Cont.evalCont(always_odd(10))
print("最后结果:", last, "attempts:", attempts)
assert(last == 21 and attempts == 3)

print("\n=== 独立 attrs.__Retry__：一次成功无需重试 ===")
local cont_env = require("cont_env")
local n = 0
local step = function(x)
  n = n + 1
  return Cont.unit(x + 1)
end
local retried = cont_env.attrs.__Retry__(4, function(a)
  return a < 0
end)(step)
assert(Cont.evalCont(retried(5)) == 6 and n == 1)

print("\ncont_env_attrs_retry OK")
