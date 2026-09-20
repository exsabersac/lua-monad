#!/usr/bin/env lua
-- fx_stop_cancel.lua — 中途 fx.stop；cancel token 在下一次 wait 前中止
-- 在仓库根目录执行：lua examples/fx_stop_cancel.lua

package.path = "src/?.lua;" .. package.path

local Cont = require("cont")
local fx = require("fx")
local print, assert, tostring = print, assert, tostring

local instant = {
  wait = function(req)
    print(string.format("  [handler] wait %.3fs", req.seconds or 0))
    return true
  end,
  click = function(req)
    print(string.format("  [handler] click %s", tostring(req.target)))
    return { ok = true, target = req.target }
  end,
}

------------------------------------------------------------
-- 1. 业务主动 fx.stop：不再 resume 后续步骤
------------------------------------------------------------
local stop_mid = Cont.withEnv(function(_ENV)
  function a(_)
    return fx.wait(0.01) >> function(_)
      return Cont.unit("after-wait")
    end
  end
  function b(_)
    print("  [step] b → fx.stop(\"user-abort\")")
    return fx.stop("user-abort")
  end
  function c(_)
    print("  [step] c 不应执行")
    return fx.click("nope")
  end
end)

print("=== fx.stop 中途中止 ===")
local r1 = fx.run(stop_mid(nil), instant)
assert(r1.ok == false and r1.stopped == true)
assert(r1.reason == "user-abort")
print("结果: stopped reason=", tostring(r1.reason))

------------------------------------------------------------
-- 2. cancel token：下一次 yield 前检测到 cancelled
------------------------------------------------------------
local long_flow = Cont.withEnv(function(_ENV)
  function first(_)
    return fx.wait(0.01) >> function(_)
      return Cont.unit(1)
    end
  end
  function second(_)
    return fx.wait(0.01) >> function(_)
      return Cont.unit(2)
    end
  end
  function third(_)
    return fx.click("done")
  end
end)

print("\n=== cancel token：第一次 wait 后标记 cancelled ===")
local token = { cancelled = false }
local nwait = 0
local cancel_handlers = {
  wait = function(req)
    nwait = nwait + 1
    print(string.format("  [handler] wait #%d", nwait))
    if nwait >= 1 then
      token.cancelled = true -- 下次进入循环前会被检测到
    end
    return true
  end,
  click = function(req)
    print("  [handler] click 不应执行")
    return { ok = true, target = req.target }
  end,
}

local r2 = fx.run(long_flow(nil), cancel_handlers, { cancel = token })
assert(r2.ok == false and r2.stopped == true)
assert(r2.reason == "cancelled")
assert(nwait == 1, "only first wait should run before cancel on next yield")
print("结果: stopped reason=", tostring(r2.reason), "waits=", nwait)

------------------------------------------------------------
-- 3. cancel 函数形式
------------------------------------------------------------
print("\n=== cancel 函数：第二次 yield 前返回 true ===")
local ticks = 0
local r3 = fx.run(long_flow(nil), instant, {
  cancel = function()
    ticks = ticks + 1
    return ticks > 1 -- 第一次 Yielded 放行，第二次前取消
  end,
})
assert(r3.stopped and r3.reason == "cancelled")
print("结果: cancelled after ticks=", ticks)

print("\nfx_stop_cancel OK")
