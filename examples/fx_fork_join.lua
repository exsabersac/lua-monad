#!/usr/bin/env lua
-- fx_fork_join.lua — 非结构化 Fork/Join：先 fork，中间可做别的事，再 join
-- 在仓库根目录执行：lua examples/fx_fork_join.lua
--
-- 与 when_all 对照：
--   when_all({a,b})     = 结构化：同时启动、一起等完，一个表达式
--   fork + 中间工作 + join = 非结构化：早启动，稍后再汇合
--
-- C# 对照：
--   var t = Task.Run(...);  …其它工作…;  await t;

package.path = "src/?.lua;" .. package.path

local Cont = require("cont")
local fx = require("fx")
local sched = require("fx_sched")
local print, assert, tostring = print, assert, tostring

------------------------------------------------------------
-- 1. fork 两路慢 wait，中间做 connect，再 join：wall clock ≈ max 而非 sum
------------------------------------------------------------
print("=== fork 两路 wait(0.05)，中间 connect，再 join_handles ===")
local t0 = sched.now()
local pipe1 = fx.fork(fx.wait(0.05) >> function(_) return Cont.unit("A") end) >> function(h1)
  return fx.fork(fx.wait(0.05) >> function(_) return Cont.unit("B") end) >> function(h2)
    return fx.connect("mid") >> function(conn)
      return fx.join_handles({ h1, h2 }) >> function(vals)
        return Cont.unit({ vals = vals, host = conn.host })
      end
    end
  end
end
local r1 = fx.run(pipe1, nil, { verbose_wait = true })
local e1 = sched.now() - t0
assert(r1.ok, "fork/join pipeline should succeed")
assert(r1.value.vals[1] == "A" and r1.value.vals[2] == "B")
assert(r1.value.host == "mid")
print(string.format("  vals=%s,%s host=%s elapsed=%.3fs (期望 < 0.09；串行会 ≈ 0.10)",
  r1.value.vals[1], r1.value.vals[2], r1.value.host, e1))
assert(e1 < 0.09, "fork/join waits should be parallel, got " .. tostring(e1))
assert(e1 >= 0.04)

------------------------------------------------------------
-- 2. fork 后只 join 一个；对照 when_all
------------------------------------------------------------
print("\n=== fork 后 join 单个；对照 when_all ===")
local pipe2 = fx.fork(fx.wait(0.03) >> function(_) return Cont.unit(42) end) >> function(h)
  return fx.click("btn") >> function(clk)
    return fx.join(h) >> function(v)
      return Cont.unit({ joined = v, click = clk.target })
    end
  end
end
local r2 = fx.run(pipe2)
assert(r2.ok and r2.value.joined == 42 and r2.value.click == "btn")
print("  fork+join →", r2.value.joined, r2.value.click)

local r_wa = fx.run(fx.when_all({
  fx.wait(0.01) >> function(_) return Cont.unit("x") end,
  Cont.unit("y"),
}))
assert(r_wa.ok and r_wa.value[1] == "x" and r_wa.value[2] == "y")
print("  when_all 对照 →", r_wa.value[1], r_wa.value[2])

------------------------------------------------------------
-- 3. 子任务 Failed：join 传播失败
------------------------------------------------------------
print("\n=== 子 Failed → join 传播 ===")
local pipe3 = fx.fork(fx.fail("child-boom")) >> function(h)
  return fx.join(h)
end
local r3 = fx.run(pipe3)
assert(r3.ok == false and r3.failed == true)
assert(r3.error == "child-boom")
print("  failed error=", tostring(r3.error))

print("\nfx_fork_join OK")
