#!/usr/bin/env lua
-- coro_interactive.lua — yield 请求、resume 回答（回声 / 累加）
-- 在仓库根目录执行：lua examples/coro_interactive.lua

package.path = "src/?.lua;" .. package.path

local Cont = require("cont")
local Coro = require("coro")

print("=== 回声：yield 提问，resume 带回答案===")
local echo_body = Coro.yield("你叫什么名字？") >> function(name)
  return Coro.yield("你好，" .. tostring(name) .. "！再输入一个数字：") >> function(n)
    return Cont.unit("收到数字 " .. tostring(n) .. "，会话结束")
  end
end

-- 模拟用户依次回答
local replies = { "小明", 42 }
local ri = 0
local echo_final = Coro.run(echo_body, function(prompt)
  ri = ri + 1
  local answer = replies[ri]
  print("  协程问:", prompt)
  print("  用户答:", answer)
  return answer
end)
print("最终:", echo_final)

print("\n=== 累加：多次 yield 请求加数===")
local function accumulate(rounds)
  local function go(i, sum)
    if i > rounds then
      return Cont.unit(sum)
    end
    return Coro.yield({ ask = "加数#" .. i, so_far = sum }) >> function(x)
      return go(i + 1, sum + x)
    end
  end
  return go(1, 0)
end

local addends = { 10, 20, 7 }
local ai = 0
local total = Coro.run(accumulate(3), function(req)
  ai = ai + 1
  local x = addends[ai]
  print(string.format("  请求 %s（当前和=%s）→ 回答 %s", req.ask, tostring(req.so_far), tostring(x)))
  return x
end)
print("累加结果:", total)
