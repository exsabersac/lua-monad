#!/usr/bin/env lua
-- cont_env_plain_steps.lua — withEnv 普通 a→b 与 Cont 步进混写
-- 在仓库根目录执行：lua examples/cont_env_plain_steps.lua
--
-- 管道步骤可写成普通函数（返回值自动 Cont.unit）；若已返回 Cont
-- （如 Cont.unit、fx.wait、>> 链），则原样参与组合。

package.path = "src/?.lua;" .. package.path

local Cont = require("cont")
local fx = require("fx")
local print, assert = print, assert

-- 纯算术：全部普通 a→b
local arith = Cont.withEnv(function(_ENV)
  function add1(x)
    return x + 1
  end
  function times2(x)
    return x * 2
  end
end)
assert(Cont.evalCont(arith(3)) == 8) -- (3+1)*2
print("plain arith (3+1)*2:", Cont.evalCont(arith(3)))

-- 混写：普通步进 + Cont.unit 链 + fx.wait
local mixed = Cont.withEnv(function(_ENV)
  function bump(x)
    return x + 10 -- 普通返回 → 自动提升
  end

  function pause(x)
    -- 已是 Cont：不重复包
    return fx.wait(0.01) >> function(_)
      return Cont.unit(x)
    end
  end

  function tag(x)
    return Cont.unit({ n = x, ok = true })
  end
end)

local r = fx.run(mixed(5))
assert(r.ok and r.value.n == 15 and r.value.ok == true)
print("mixed plain + fx.wait + Cont.unit:", r.value.n, r.value.ok)

-- 属性仍作用在「已提升」的步进上（__Trace__ 需要 Cont）
local traced = Cont.withEnv(function(_ENV)
  __Trace__("plain")
  function add3(x)
    return x + 3
  end
end)
local tv = Cont.evalCont(traced(1))
assert(tv == 4)
print("plain + __Trace__:", tv)

-- Cont.is 识别
assert(Cont.is(Cont.unit(1)) == true)
assert(Cont.is(42) == false)
assert(Cont.isCont == Cont.is)
print("Cont.is ok")

print("cont_env_plain_steps OK")
