#!/usr/bin/env lua
-- fx_fail_catch.lua — fx.fail → Coro Failed；Cont.catch 演示 Cont.throw
-- 在仓库根目录执行：lua examples/fx_fail_catch.lua

package.path = "src/?.lua;" .. package.path

local Cont = require("cont")
local Coro = require("coro")
local fx = require("fx")
local print, assert, tostring = print, assert, tostring

local instant = {
  wait = function(_) return true end,
  click = function(req) return { ok = true, target = req.target } end,
}

------------------------------------------------------------
-- 1. fx.fail → fx.run 结构化 Failed
------------------------------------------------------------
local boom = Cont.withEnv(function(_ENV)
  function prep(_)
    return fx.wait(0.01) >> function(_)
      return Cont.unit("ready")
    end
  end
  function go(_)
    print("  [step] fx.fail(\"disk-full\")")
    return fx.fail("disk-full")
  end
  function after(_)
    print("  [step] after 不应执行")
    return fx.click("x")
  end
end)

print("=== fx.fail → Failed ===")
local r1 = fx.run(boom(nil), instant)
assert(r1.ok == false and r1.failed == true)
assert(r1.error == "disk-full")
print("结果: failed error=", tostring(r1.error))

------------------------------------------------------------
-- 2. fx.try + on_fail 恢复为普通值
------------------------------------------------------------
print("\n=== fx.try on_fail 恢复 ===")
local r2 = fx.try(boom(nil), instant, {
  on_fail = function(err)
    print("  on_fail:", tostring(err))
    return { recovered = true, from = err }
  end,
})
assert(r2.ok and r2.value.recovered and r2.value.from == "disk-full")
print("恢复值:", r2.value.from)

------------------------------------------------------------
-- 3. Cont.catch + Cont.throw（纯 Cont / evalCont，不经 fx）
------------------------------------------------------------
print("\n=== Cont.throw 被 Cont.catch 接住 ===")
local ma = Cont.catch(
  Cont.unit(1) >> function(x)
    return Cont.throw("bad:" .. tostring(x)) >> function(_)
      return Cont.unit("unreachable")
    end
  end,
  function(err)
    return Cont.unit({ caught = err })
  end
)
local v = Cont.evalCont(ma)
assert(v.caught == "bad:1")
print("caught:", v.caught)

------------------------------------------------------------
-- 4. Coro.runEx 看 status
------------------------------------------------------------
print("\n=== Coro.runEx status ===")
local status, payload = Coro.runEx(fx.fail("e"), function() end)
assert(status == "failed" and payload == "e")
print("runEx:", status, payload)

print("\nfx_fail_catch OK")
