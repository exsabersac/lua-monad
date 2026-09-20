#!/usr/bin/env lua
-- fx_cancel_tree.lua — 取消传播树：session cancel 停子任务；join cancel_siblings
-- 在仓库根目录执行：lua examples/fx_cancel_tree.lua
--
-- 语义摘要：
--   · opts.cancel 置位 → 停止 nursery 内全部未完成任务（含 fork / map_parallel worker）
--   · fx.join(h, { cancel_siblings = true }) → 成功后停止「同一 fork 父」下其它未完成兄弟

package.path = "src/?.lua;" .. package.path

local Cont = require("cont")
local fx = require("fx")
local sched = require("fx_sched")
local print, assert, tostring = print, assert, tostring

------------------------------------------------------------
-- 1. cancel token：fork 慢子任务后取消 → 子不会跑完
------------------------------------------------------------
print("=== session cancel 传播到 fork 子任务 ===")
local token = { cancelled = false }
local child_done = false
local pipe1 = fx.fork(fx.wait(0.12) >> function(_)
  child_done = true
  return Cont.unit("slow-child")
end) >> function(h)
  return fx.connect("trigger") >> function(_)
    return fx.join(h)
  end
end
local t0 = sched.now()
local r1 = fx.run(pipe1, {
  connect = function(req)
    print("  [handler] connect → 置 cancelled")
    token.cancelled = true
    return { ok = true, host = req.host }
  end,
}, { cancel = token, verbose_wait = true })
local e1 = sched.now() - t0
assert(r1.ok == false and r1.stopped and r1.reason == "cancelled")
assert(child_done == false, "fork child must not complete after cancel")
print(string.format("  stopped reason=%s elapsed=%.3fs child_done=%s",
  tostring(r1.reason), e1, tostring(child_done)))
assert(e1 < 0.10)

------------------------------------------------------------
-- 2. join(..., { cancel_siblings = true })：取快者，取消慢兄弟
------------------------------------------------------------
print("\n=== join cancel_siblings：快 A 胜出，慢 B 被停 ===")
local b_done = false
local pipe2 = fx.fork(fx.wait(0.03) >> function(_)
  return Cont.unit("A")
end) >> function(hA)
  return fx.fork(fx.wait(0.20) >> function(_)
    b_done = true
    return Cont.unit("B")
  end) >> function(_hB)
    return fx.join(hA, { cancel_siblings = true }) >> function(v)
      return Cont.unit(v)
    end
  end
end
local t1 = sched.now()
local r2 = fx.run(pipe2, nil, { verbose_wait = true })
local e2 = sched.now() - t1
assert(r2.ok and r2.value == "A")
assert(b_done == false, "sibling B should be cancelled")
print(string.format("  value=%s elapsed=%.3fs b_done=%s",
  tostring(r2.value), e2, tostring(b_done)))
assert(e2 < 0.10 and e2 >= 0.02)

------------------------------------------------------------
-- 3. join_handles + cancel_siblings：保留集合内，取消集合外
------------------------------------------------------------
print("\n=== join_handles cancel_siblings：保留 h1/h2，取消 h3 ===")
local c_done = false
local pipe3 = fx.fork(fx.wait(0.02) >> function(_) return Cont.unit(1) end) >> function(h1)
  return fx.fork(fx.wait(0.02) >> function(_) return Cont.unit(2) end) >> function(h2)
    return fx.fork(fx.wait(0.20) >> function(_)
      c_done = true
      return Cont.unit(3)
    end) >> function(_h3)
      return fx.join_handles({ h1, h2 }, { cancel_siblings = true }) >> function(vals)
        return Cont.unit(vals)
      end
    end
  end
end
local t2 = sched.now()
local r3 = fx.run(pipe3)
local e3 = sched.now() - t2
assert(r3.ok and r3.value[1] == 1 and r3.value[2] == 2)
assert(c_done == false)
print(string.format("  vals=%s,%s elapsed=%.3fs c_done=%s",
  tostring(r3.value[1]), tostring(r3.value[2]), e3, tostring(c_done)))
assert(e3 < 0.10)

print("\nfx_cancel_tree OK")
