#!/usr/bin/env lua
-- cont_env_finally.lua — withEnv 的 init / finally：打开资源，退出时关闭
-- 在仓库根目录执行：lua examples/cont_env_finally.lua
--
-- 要点：
--   1. 固定名 init / finally（或 __init__ / __final__）不是管道步骤。
--   2. 亦可 __Init__() / __Finally__() 标注任意函数名。
--   3. 顺序：全部 init（定义序）→ 步骤 >> → 退出时全部 finally（定义序）。
--   4. 退出含：成功 Done、Cont.throw（外层 Cont.catch）、Coro/fx 的 Stopped|Failed。
--   5. _ENV 作参数名时，请把 type/print/tostring 收到 chunk 局部，否则查 env 得 nil。

package.path = "src/?.lua;" .. package.path

local Cont = require("cont")
local Coro = require("coro")
local fx = require("fx")
local print, assert, tostring, type = print, assert, tostring, type

------------------------------------------------------------
-- 模拟资源
------------------------------------------------------------
local function make_resource(name)
  return {
    name = name,
    open = false,
    closed_with = nil,
  }
end

------------------------------------------------------------
-- 1. 成功路径：init 打开，work，finally 关闭
------------------------------------------------------------
print("=== 1. 成功：init 打开 → 步骤 → finally 关闭 ===")
local res1 = make_resource("file-A")
local pipe_ok = Cont.withEnv(function(_ENV)
  function init(x)
    res1.open = true
    print("  [init] open", res1.name, "input=", x)
    -- 可改写进入管道的输入
    return Cont.unit(x + 1)
  end

  function work(x)
    assert(res1.open)
    print("  [work]", x)
    return Cont.unit(x * 10)
  end

  function finally(outcome)
    print("  [finally] status=", outcome.status, "value=", tostring(outcome.value))
    res1.open = false
    res1.closed_with = outcome.status
    return Cont.unit(true)
  end
end)

local v = Cont.evalCont(pipe_ok(3))
print("结果:", v)
assert(v == 40) -- init: 3→4；work: 4*10
assert(res1.open == false and res1.closed_with == "done")

------------------------------------------------------------
-- 2. Cont.throw：finally 仍跑，再交给外层 catch
------------------------------------------------------------
print("\n=== 2. Cont.throw：finally 后外层 catch ===")
local res2 = make_resource("file-B")
local pipe_throw = Cont.withEnv(function(_ENV)
  function init(x)
    res2.open = true
    print("  [init] open", res2.name)
    return Cont.unit(x)
  end
  function boom(_)
    print("  [boom] Cont.throw")
    return Cont.throw("disk-full")
  end
  function finally(outcome)
    print("  [finally] status=", outcome.status, "error=", tostring(outcome.error))
    res2.open = false
    res2.closed_with = outcome.status
    return Cont.unit(true)
  end
end)

local caught = Cont.evalCont(Cont.catch(pipe_throw(1), function(err)
  return Cont.unit({ recovered = err })
end))
print("catch 结果:", caught.recovered)
assert(caught.recovered == "disk-full")
assert(res2.open == false and res2.closed_with == "failed")

------------------------------------------------------------
-- 3. Coro.stop / Coro.fail
------------------------------------------------------------
print("\n=== 3. Coro.stop：finally 收到 stopped ===")
local res3 = make_resource("file-C")
local pipe_stop = Cont.withEnv(function(_ENV)
  function init(x)
    res3.open = true
    return Cont.unit(x)
  end
  function mid(_)
    print("  [mid] Coro.stop")
    return Coro.stop("user-cancel")
  end
  function after(_)
    print("  [after] 不应执行")
    return Cont.unit(999)
  end
  function finally(outcome)
    print("  [finally] status=", outcome.status, "reason=", tostring(outcome.reason))
    res3.open = false
    res3.closed_with = outcome.status
    return Cont.unit(true)
  end
end)

local st, reason = Coro.runEx(pipe_stop(0), function()
  return true
end)
print("runEx:", st, reason)
assert(st == "stopped" and reason == "user-cancel")
assert(res3.open == false and res3.closed_with == "stopped")

print("\n=== 3b. Coro.fail ===")
local res3b = make_resource("file-C2")
local pipe_fail = Cont.withEnv(function(_ENV)
  function init(x)
    res3b.open = true
    return Cont.unit(x)
  end
  function mid(_)
    return Coro.fail("boom")
  end
  function finally(outcome)
    res3b.open = false
    res3b.closed_with = outcome.status
    return Cont.unit(true)
  end
end)
st, reason = Coro.runEx(pipe_fail(0), function()
  return true
end)
assert(st == "failed" and reason == "boom")
assert(res3b.open == false and res3b.closed_with == "failed")
print("Failed 后 closed_with=", res3b.closed_with)

------------------------------------------------------------
-- 4. __Init__ / __Finally__ 标注名 + 固定名 finally 一起跑
------------------------------------------------------------
print("\n=== 4. __Init__ / __Finally__ 与固定名并存（定义序）===")
local log = {}
local pipe_mark = Cont.withEnv(function(_ENV)
  __Init__()
  function open_db(x)
    log[#log + 1] = "open_db"
    return Cont.unit(x)
  end

  function step(x)
    log[#log + 1] = "step"
    return Cont.unit(x + 1)
  end

  __Finally__()
  function close_db(outcome)
    log[#log + 1] = "close_db:" .. outcome.status
    return Cont.unit(true)
  end

  function finally(outcome)
    log[#log + 1] = "finally:" .. outcome.status
    return Cont.unit(true)
  end
end)
assert(Cont.evalCont(pipe_mark(1)) == 2)
print("顺序:", table.concat(log, " → "))
-- finally 写在 close_db 之后，故 close_db 先、finally 后？
-- 定义序：open_db(init), step, close_db(finally), finally(finally)
-- 但上面 finally 函数写在 close_db 之后，所以 cleanups 序：close_db, finally
assert(log[1] == "open_db" and log[2] == "step")
assert(log[3] == "close_db:done" and log[4] == "finally:done")

------------------------------------------------------------
-- 5. Cont.finally / Cont.init_finally（withEnv 外）
------------------------------------------------------------
print("\n=== 5. Cont.finally / Cont.init_finally ===")
local flagged = false
local m = Cont.init_finally(
  Cont.unit(21),
  function()
    print("  [init_finally] init")
    return Cont.unit(true)
  end,
  function(outcome)
    flagged = true
    print("  [init_finally] finally", outcome.status, outcome.value)
    return Cont.unit(true)
  end
)
assert(Cont.evalCont(m) == 21 and flagged)

------------------------------------------------------------
-- 6. fx.stop 路径（可选：解释器会话）
------------------------------------------------------------
print("\n=== 6. fx.run + fx.stop：finally 关闭 ===")
local res6 = make_resource("sock")
local flow = Cont.withEnv(function(_ENV)
  function init(_)
    res6.open = true
    print("  [init] open sock")
    return Cont.unit(true)
  end
  function wait_a_bit(_)
    return fx.wait(0.001) >> function()
      return Cont.unit(true)
    end
  end
  function abort(_)
    print("  [abort] fx.stop")
    return fx.stop("bye")
  end
  function finally(outcome)
    print("  [finally] fx", outcome.status, tostring(outcome.reason))
    res6.open = false
    res6.closed_with = outcome.status
    return Cont.unit(true)
  end
end)

local r6 = fx.run(flow(nil), {
  wait = function()
    return true
  end,
})
assert(r6.stopped and r6.reason == "bye")
assert(res6.open == false and res6.closed_with == "stopped")
print("fx 结果: stopped, resource closed")

print("\ncont_env_finally OK")
