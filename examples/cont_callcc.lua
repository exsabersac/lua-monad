#!/usr/bin/env lua
-- cont_callcc.lua — Cont.callCC 提前退出 / abort 风格示例
-- 在仓库根目录执行：lua examples/cont_callcc.lua

package.path = "src/?.lua;" .. package.path

local Cont = require("cont")

print("=== callCC：正常路径（不调用 escape）===")
local normal = Cont.callCC(function(escape)
  -- 不调用 escape，整段像普通 Cont 绑定
  return Cont.unit(10) >> function(x)
    return Cont.unit(x + 1)
  end
end)
print("evalCont:", Cont.evalCont(normal))  -- 11

print("\n=== callCC：提前跳出（abort 风格）===")
-- escape(v) 忽略后续续延，直接把 v 交给 callCC 的外层续延
local aborted = Cont.callCC(function(escape)
  return Cont.unit("开始") >> function(_)
    print("  （即将 escape(42)，后面的 999 不会成为结果）")
    return escape(42) >> function(_)
      return Cont.unit(999)  -- 不会执行到对最终答案的贡献
    end
  end
end)
print("evalCont:", Cont.evalCont(aborted))  -- 42

print("\n=== callCC：条件提前返回===")
local function find_first_even(xs)
  return Cont.callCC(function(escape)
    local function loop(i)
      if i > #xs then
        return Cont.unit(nil)
      end
      local v = xs[i]
      if v % 2 == 0 then
        return escape(v)  -- 找到偶数立刻跳出
      end
      return Cont.unit(nil) >> function()
        return loop(i + 1)
      end
    end
    return loop(1)
  end)
end

print("find_first_even({1,3,4,6}):", Cont.evalCont(find_first_even({ 1, 3, 4, 6 })))
print("find_first_even({1,3,5}):", tostring(Cont.evalCont(find_first_even({ 1, 3, 5 }))))
