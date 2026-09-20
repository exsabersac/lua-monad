#!/usr/bin/env lua
-- demo.lua — 各 monad 与 Cont CPS 协程的简短可运行演示
-- 在仓库根目录执行：lua examples/demo.lua

package.path = "src/?.lua;" .. package.path

local Maybe = require("maybe")
local List = require("list")
local State = require("state")
local Status = require("status")
local Cont = require("cont")
local Coro = require("coro")

print("=== Maybe ===")
-- >> 即 bind：Just 继续，Nothing 会短路
local m = Maybe.Just(3) >> function(x)
  if x > 0 then return Maybe.Just(x * 2) else return Maybe.Nothing() end
end
print("Just(3) >> double:", m.tag, m.value)

print("\n=== List ===")
-- 每个元素映射成列表再展平
local xs = List.wrap({ 1, 2, 3 }) >> function(x)
  return List.wrap({ x, x * 10 })
end
io.write(">> flatten: ")
for i, v in ipairs(xs) do io.write(v .. (i < #xs and "," or "")) end
print()

print("\n=== State ===")
-- get 读状态 → put 写回 → .. 丢弃 put 的结果，留下 unit 的字符串
local prog = State.get() >> function(n)
  return State.put(n + 1) .. State.unit("was " .. tostring(n))
end
local a, s = State.runState(prog, 41)
print("runState:", a, "new state:", s)

print("\n=== Status ===")
local ok = Status.Ok(10) >> function(x) return Status.Ok(x / 2) end
-- Err .. Ok：左边短路，右边不执行
local err = Status.Err("fail") .. Status.Ok(1)
print("Ok path:", ok.tag, ok.value)
print("Err path:", err.tag, err.error)

print("\n=== Cont + CPS coro ===")
-- yield 挂起；resume 把值送回 bind 的续函数
local body = Coro.yield("hello") >> function(reply)
  return Coro.yield("got:" .. tostring(reply)) >> function(reply2)
    return Cont.unit("finished with " .. tostring(reply2))
  end
end

local step = Coro.start(body)
while Coro.isYielded(step) do
  print("  yielded:", step.value)
  step = Coro.resume(step, #tostring(step.value))
end
print("  done:", step.value)
