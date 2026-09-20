#!/usr/bin/env lua
-- cont_env_attrs_timeout.lua — __Timeout__(secs[, on_timeout])：合作式超时
-- 在仓库根目录执行：lua examples/cont_env_attrs_timeout.lua
--
-- 重要：超时在「步骤经 bind 交出值 a 之后」用 os.clock 检查；
-- 无法打断同步步中途的忙等（非抢占）。

package.path = "src/?.lua;" .. package.path

local Cont = require("cont")
local print, assert, tostring, os = print, assert, tostring, os

print("=== __Timeout__：慢步超时 → 默认 {tag=timeout,...} ===")
local slow = Cont.withEnv(function(_ENV)
  -- 极短阈值，忙等后必超时
  __Timeout__(0.001)
  function busy(x)
    local t0 = os.clock()
    while os.clock() - t0 < 0.02 do
    end
    return Cont.unit(x + 1)
  end
end)

local r = Cont.evalCont(slow(10))
print("结果 tag=", r.tag, "value=", r.value, "elapsed≈", string.format("%.4f", r.elapsed))
assert(r.tag == "timeout")
assert(r.value == 11)
assert(type(r.elapsed) == "number" and r.elapsed > 0.001)

print("\n=== __Timeout__：快步未超时，原值通过 ===")
local fast = Cont.withEnv(function(_ENV)
  __Timeout__(1.0)
  function add1(x)
    return Cont.unit(x + 1)
  end
end)
local v = Cont.evalCont(fast(5))
print("结果:", v)
assert(v == 6)

print("\n=== __Timeout__ + 自定义 on_timeout ===")
local custom = Cont.withEnv(function(_ENV)
  __Timeout__(0.001, function(a, elapsed)
    return Cont.unit({ ok = false, got = a, took = elapsed })
  end)
  function busy(x)
    local t0 = os.clock()
    while os.clock() - t0 < 0.02 do
    end
    return Cont.unit(x)
  end
end)
local c = Cont.evalCont(custom(42))
assert(c.ok == false and c.got == 42 and c.took > 0.001)
print("自定义 on_timeout ok")

print("\n=== 独立 cont_env.attrs.__Timeout__ ===")
local cont_env = require("cont_env")
local step = function(x)
  return Cont.unit(x)
end
local wrapped = cont_env.attrs.__Timeout__(10)(step)
assert(Cont.evalCont(wrapped(1)) == 1)

print("\ncont_env_attrs_timeout OK")
