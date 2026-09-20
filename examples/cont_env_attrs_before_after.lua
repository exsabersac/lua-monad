#!/usr/bin/env lua
-- cont_env_attrs_before_after.lua — __Before__ / __After__ 日志与多属性组合
-- 在仓库根目录执行：lua examples/cont_env_attrs_before_after.lua
--
-- 注意：若 body 参数名为 _ENV，自由名（print/tostring）会查 env 表；
-- 本示例在 chunk 顶层缓存全局，或用 env. 前缀调用属性。

package.path = "src/?.lua;" .. package.path

local Cont = require("cont")
local print, assert, table, tostring = print, assert, table, tostring

local log = {}

local function push(msg)
  log[#log + 1] = msg
  print("  " .. msg)
end

print("=== __Before__ + __After__ 包一层步骤 ===")
local pipe = Cont.withEnv(function(_ENV)
  __Before__(function(x)
    push("before:" .. tostring(x))
    return Cont.unit(x)
  end)
  __After__(function(x)
    push("after:" .. tostring(x))
    return Cont.unit(x)
  end)
  function add10(x)
    push("add10:" .. tostring(x))
    return Cont.unit(x + 10)
  end

  function times2(x)
    push("times2:" .. tostring(x))
    return Cont.unit(x * 2)
  end
end)

-- add10 被 Before/After 包：before → add10 → after → times2
local v = Cont.evalCont(pipe(5))
print("结果:", v)
assert(v == 30) -- (5+10)*2

local expect = {
  "before:5",
  "add10:5",
  "after:15",
  "times2:15",
}
assert(#log == #expect)
for i, s in ipairs(expect) do
  assert(log[i] == s, "log[" .. i .. "]=" .. tostring(log[i]))
end
print("日志顺序:", table.concat(log, " | "))

print("\n=== 独立 cont_env.attrs.__Wrap__ ===")
local cont_env = require("cont_env")
local step = function(x)
  return Cont.unit(x + 1)
end
local wrapped = cont_env.attrs.__Wrap__(function(s)
  return function(x)
    push("wrap-in:" .. tostring(x))
    return s(x) >> function(y)
      push("wrap-out:" .. tostring(y))
      return Cont.unit(y)
    end
  end
end)(step)
local w = Cont.evalCont(wrapped(7))
assert(w == 8)

print("\ncont_env_attrs_before_after OK")
