#!/usr/bin/env lua
-- cont_catch_throw.lua — Cont.throw / Cont.catch / Cont.protect（无 fx）
-- 在仓库根目录执行：lua examples/cont_catch_throw.lua

package.path = "src/?.lua;" .. package.path

local Cont = require("cont")
local print, assert, tostring, pcall = print, assert, tostring, pcall

print("=== 正常 catch ===")
local ok_v = Cont.evalCont(Cont.catch(
  Cont.unit(10) >> function(n)
    if n > 5 then
      return Cont.throw({ code = 1, msg = "too big" })
    end
    return Cont.unit(n)
  end,
  function(err)
    return Cont.unit("fallback:" .. tostring(err.msg))
  end
))
assert(ok_v == "fallback:too big")
print("结果:", ok_v)

print("\n=== 嵌套 catch：内层接住 ===")
local nested = Cont.evalCont(Cont.catch(
  Cont.catch(
    Cont.throw("inner"),
    function(e)
      return Cont.unit("inner-handled:" .. tostring(e))
    end
  ),
  function(e)
    return Cont.unit("outer:" .. tostring(e))
  end
))
assert(nested == "inner-handled:inner")
print("结果:", nested)

print("\n=== 嵌套 catch：内层再 throw 到外层 ===")
local rethrow = Cont.evalCont(Cont.catch(
  Cont.catch(
    Cont.throw("x"),
    function(_e)
      return Cont.throw("from-inner")
    end
  ),
  function(e)
    return Cont.unit("outer-got:" .. tostring(e))
  end
))
assert(rethrow == "outer-got:from-inner")
print("结果:", rethrow)

print("\n=== 未捕获 Cont.throw → Lua error ===")
local ok, err = pcall(function()
  Cont.evalCont(Cont.throw("oops"))
end)
assert(not ok)
assert(tostring(err):find("uncaught Cont.throw", 1, true))
print("error:", err)

print("\n=== Cont.protect：无 catch 时 Lua error 变错误表 ===")
local prot = Cont.evalCont(Cont.protect(Cont.wrap(function(_k)
  error("boom-lua", 0)
end)))
assert(type(prot) == "table" and prot.tag == "error")
assert(tostring(prot.error):find("boom-lua", 1, true))
print("protect:", prot.tag, prot.error)

print("\n=== Cont.protect 在 catch 内：Lua error 走 handler ===")
local via_catch = Cont.evalCont(Cont.catch(
  Cont.protect(Cont.wrap(function(_k)
    error("via", 0)
  end)),
  function(e)
    return Cont.unit("caught-lua:" .. tostring(e))
  end
))
-- protect 在有 catch 时把 Lua error 交给栈顶 handler
assert(tostring(via_catch):find("via", 1, true) or tostring(via_catch):find("caught-lua", 1, true))
print("via_catch:", via_catch)

print("\ncont_catch_throw OK")
