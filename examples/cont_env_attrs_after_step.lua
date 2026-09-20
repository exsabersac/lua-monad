#!/usr/bin/env lua
-- cont_env_attrs_after_step.lua — __AfterStep__ / __BeforeStep__ 管道顺序约束
-- 在仓库根目录执行：lua examples/cont_env_attrs_after_step.lua
--
-- 对比：__Before__ / __After__ 是「包一层 Cont」（改步骤本身）；
--       __BeforeStep__ / __AfterStep__ 是「改步骤在管道中的相对位置」（拓扑排序）。

package.path = "src/?.lua;" .. package.path

local Cont = require("cont")
local cont_env = require("cont_env")
local print, assert, table, tostring = print, assert, table, tostring

print("=== 源码后写的步骤，用 AfterStep 排到前面步骤之后 ===")
-- 定义序：later, early；约束：later AfterStep early → 管道 early >> later
local pipe1 = Cont.withEnv(function(_ENV)
  __AfterStep__("early")
  function later(x)
    return Cont.unit(x * 10)
  end
  function early(x)
    return Cont.unit(x + 1)
  end
end)
local v1 = Cont.evalCont(pipe1(2))
print("结果:", v1, "（期望 (2+1)*10 = 30）")
assert(v1 == 30)

print("\n=== BeforeStep：把 mid 插到 last 之前 ===")
-- 定义序：first, last, mid；约束 mid BeforeStep last → first >> mid >> last
local pipe2 = Cont.withEnv(function(_ENV)
  function first(x)
    return Cont.unit(x + 1)
  end
  function last(x)
    return Cont.unit(x * 3)
  end
  __BeforeStep__("last")
  function mid(x)
    return Cont.unit(x + 10)
  end
end)
local v2 = Cont.evalCont(pipe2(1))
print("结果:", v2, "（期望 ((1+1)+10)*3 = 36）")
assert(v2 == 36)

print("\n=== 与 __Helper__ 混用：助手不进序，不影响 AfterStep ===")
local pipe3 = Cont.withEnv(function(_ENV)
  __Helper__()
  function bump(x)
    return Cont.unit(x + 100)
  end
  __AfterStep__("a")
  function b(x)
    return bump(x) >> function(y)
      return Cont.unit(y * 2)
    end
  end
  function a(x)
    return Cont.unit(x + 1)
  end
end)
local v3 = Cont.evalCont(pipe3(3))
print("结果:", v3, "（期望 a 后 b：(3+1+100)*2 = 208）")
assert(v3 == 208)

print("\n=== 独立 cont_env.attrs 描述符 ===")
local d1 = cont_env.attrs.__AfterStep__("foo")
local d2 = cont_env.attrs.__BeforeStep__("bar")
assert(type(d1) == "table" and d1.__attr_after_step == "foo")
assert(type(d2) == "table" and d2.__attr_before_step == "bar")
print("attrs.__AfterStep__/__BeforeStep__ 描述符 OK")

print("\ncont_env_attrs_after_step OK")
