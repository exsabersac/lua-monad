#!/usr/bin/env lua
-- coro_generator.lua — 用 Coro.yield 实现 1..n 生成器，collect / run 驱动
-- 在仓库根目录执行：lua examples/coro_generator.lua

package.path = "src/?.lua;" .. package.path

local Cont = require("cont")
local Coro = require("coro")

-- 生成器：依次 yield 1..n，最终 Done 值为 "done:"..n
local function range(n)
  local function go(i)
    if i > n then
      return Cont.unit("done:" .. tostring(n))
    end
    return Coro.yield(i) >> function(_)
      return go(i + 1)
    end
  end
  return go(1)
end

print("=== collect：收集全部 yield 载荷===")
local yields, final = Coro.collect(range(5))
io.write("yields: ")
for i, v in ipairs(yields) do
  io.write(tostring(v) .. (i < #yields and "," or ""))
end
print()
print("final:", final)

print("\n=== run：自定义 handler（打印并原样回传）===")
local fin2 = Coro.run(range(3), function(v)
  print("  yielded:", v)
  return v  -- resume 输入；生成器里忽略
end)
print("run final:", fin2)

print("\n=== step：手动推进一步===")
local ans = Coro.start(range(2))
while Coro.isYielded(ans) do
  print("  step saw:", ans.value)
  ans = Coro.step(ans, true)
end
print("  step done:", ans.value)
