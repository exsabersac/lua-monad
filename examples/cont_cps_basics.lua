#!/usr/bin/env lua
-- cont_cps_basics.lua — Cont CPS 基础：加法链、阶乘、勾股风格串联
-- 在仓库根目录执行：lua examples/cont_cps_basics.lua

package.path = "src/?.lua;" .. package.path

local Cont = require("cont")

print("=== CPS 加法（>> 串联）===")
local add = Cont.unit(2) >> function(x)
  return Cont.unit(3) >> function(y)
    return Cont.unit(x + y)
  end
end
print("2+3 via Cont:", Cont.evalCont(add))

print("\n=== 勾股风格：a²+b² 再开方（示意）===")
local function square(n)
  return Cont.unit(n * n)
end

local pyth = Cont.unit(3) >> function(a)
  return square(a) >> function(a2)
    return Cont.unit(4) >> function(b)
      return square(b) >> function(b2)
        return Cont.unit(a2 + b2) >> function(sum)
          return Cont.unit(math.sqrt(sum))
        end
      end
    end
  end
end
print("hypot(3,4):", Cont.evalCont(pyth))

print("\n=== 阶乘（递归 Cont）===")
local function fact(n)
  if n <= 1 then
    return Cont.unit(1)
  end
  return fact(n - 1) >> function(r)
    return Cont.unit(n * r)
  end
end
print("fact(5):", Cont.evalCont(fact(5)))

print("\n=== mapCont / withCont 小对比===")
-- mapCont：改答案；withCont：改续延
local base = Cont.unit(5)
print("mapCont (+10):", Cont.evalCont(Cont.mapCont(function(r) return r + 10 end, base)))
print("withCont (×2):", Cont.evalCont(Cont.withCont(function(k)
  return function(a) return k(a * 2) end
end, base)))

print("\n=== shift / reset 定界续延===")
-- 定界续延为 λx. x*2，故 eval(k(3))+eval(k(4)) = 6+8 = 14
local delimited = Cont.bind(
  Cont.shift(function(k)
    return Cont.unit(Cont.evalCont(k(3)) + Cont.evalCont(k(4)))
  end),
  function(x)
    return Cont.unit(x * 2)
  end
)
print("reset(shift ... *2):", Cont.reset(delimited))
