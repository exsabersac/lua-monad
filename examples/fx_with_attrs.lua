#!/usr/bin/env lua
-- fx_with_attrs.lua — withEnv 属性（__Require__ / __Trace__）包住使用 fx.wait 的步骤
-- 在仓库根目录执行：lua examples/fx_with_attrs.lua
--
-- 说明：属性改的是 Cont 步骤包装；异步仍由 Coro.yield + fx.run 解释器兑现。
-- 排队先 Trace 再 Require → Require(Trace(step))：拒绝时不进 Trace、也不进 fx.wait。

package.path = "src/?.lua;" .. package.path

local Cont = require("cont")
local fx = require("fx")
local print, assert, type, tostring = print, assert, type, tostring

-- 单步管道：Require + Trace 包住 fx.wait
local gated = Cont.withEnv(function(_ENV)
  -- 先 Trace 再 Require → 折成 Require(Trace(step))：拒绝时不进 Trace/wait
  __Trace__("gated_wait")
  __Require__(function(x)
    return type(x) == "table" and x.flag == true
  end)
  function gated_wait(st)
    return fx.wait(0.01) >> function(_)
      st.waited = true
      return Cont.unit(st)
    end
  end
end)

-- 多步：boot →（Require+Trace 的 wait）→ finish；通过时走完整链
local flow = Cont.withEnv(function(_ENV)
  function boot(x)
    print("  [step] boot")
    return Cont.unit(x)
  end

  __Trace__("pause")
  __Require__(function(x)
    return type(x) == "table" and x.flag == true
  end)
  function pause(st)
    print("  [step] pause (fx.wait)")
    return fx.wait(0.01) >> function(_)
      st.waited = true
      return Cont.unit(st)
    end
  end

  function finish(st)
    -- 若上游 Require 拒绝，st 已是 {tag="rejected",...}；此处原样传递
    if type(st) == "table" and st.tag == "rejected" then
      print("  [step] finish skipped (rejected)")
      return Cont.unit(st)
    end
    print("  [step] finish")
    st.done = true
    return Cont.unit(st)
  end
end)

local instant_wait = {
  wait = function(req)
    print(string.format("  [handler] instant wait %.3fs", req.seconds or 0))
    return true
  end,
}

print("=== 单步：Require 通过 → Trace + fx.wait ===")
local r1 = fx.run(gated({ flag = true, n = 1 }), instant_wait)
assert(r1.ok)
local ok1 = r1.value
assert(ok1.waited == true and ok1.n == 1)
print("结果: waited=", tostring(ok1.waited))

print("\n=== 单步：Require 拒绝 → 不进 Trace/wait ===")
local rrej = fx.run(gated({ flag = false }), instant_wait)
assert(rrej.ok)
local rej = rrej.value
assert(rej.tag == "rejected" and rej.value.flag == false)
print("拒绝:", rej.tag)

print("\n=== 多步 flow：flag=true 完整走完 ===")
local r2 = fx.run(flow({ flag = true }), instant_wait)
assert(r2.ok)
local ok2 = r2.value
assert(ok2.waited == true and ok2.done == true)

print("\n=== 多步 flow：flag=false 在 pause 被拒 ===")
local rrej2 = fx.run(flow({ flag = false }), instant_wait)
assert(rrej2.ok)
local rej2 = rrej2.value
assert(rej2.tag == "rejected")

print("\nfx_with_attrs OK")
