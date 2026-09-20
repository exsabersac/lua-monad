#!/usr/bin/env lua
-- cont_env_attrs_require_trace.lua — __Require__ 步前校验 + __Trace__ 前后日志
-- 在仓库根目录执行：lua examples/cont_env_attrs_require_trace.lua

package.path = "src/?.lua;" .. package.path

local Cont = require("cont")
local print, assert, tostring, type = print, assert, tostring, type

print("=== __Require__：正数才进入步骤 ===")
local gated = Cont.withEnv(function(_ENV)
  __Require__(function(x)
    return type(x) == "number" and x > 0
  end)
  function double(x)
    return Cont.unit(x * 2)
  end
end)

local ok = Cont.evalCont(gated(4))
print("4 →", ok)
assert(ok == 8)

local rej = Cont.evalCont(gated(-1))
print("拒绝:", rej.tag, rej.value)
assert(rej.tag == "rejected" and rej.value == -1)

print("\n=== __Require__ + 自定义 on_fail ===")
local custom = Cont.withEnv(function(_ENV)
  __Require__(function(x)
    return x ~= nil
  end, function(x)
    return Cont.unit({ err = "nil_input" })
  end)
  function id(x)
    return Cont.unit(x)
  end
end)
local e = Cont.evalCont(custom(nil))
assert(e.err == "nil_input")
assert(Cont.evalCont(custom("hi")) == "hi")

print("\n=== __Trace__：前后 print，值不变 ===")
local traced = Cont.withEnv(function(_ENV)
  __Trace__("add1")
  function add1(x)
    return Cont.unit(x + 1)
  end
  function times2(x)
    return Cont.unit(x * 2)
  end
end)
-- (3+1)*2 = 8；Trace 只包 add1
local t = Cont.evalCont(traced(3))
print("结果:", t)
assert(t == 8)

print("\n=== Require + Trace 叠用 ===")
-- 排队序：先 Trace 再 Require → 折成 Require(Trace(step))：
-- 拒绝时不进 Trace；通过才打 before/after。
local both = Cont.withEnv(function(_ENV)
  __Trace__("safe")
  __Require__(function(x)
    return x >= 0
  end)
  function bump(x)
    return Cont.unit(x + 10)
  end
end)
assert(Cont.evalCont(both(1)) == 11)
local bad = Cont.evalCont(both(-5))
assert(bad.tag == "rejected" and bad.value == -5)
print("拒绝 -5 不经 Trace（无 before/after 行）")

print("\ncont_env_attrs_require_trace OK")
