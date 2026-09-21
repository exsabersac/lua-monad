#!/usr/bin/env lua
-- register.lua — Core · fx.register / unregister：自定义效果 kind
--
-- 用途：把业务特有异步效果挂进解释器；handler(req)→值 或 异步约定。
-- 参数：kind(string), handler, opts?；unregister(kind) 撤销。
-- 与 Sugar connect/click：教学 mock；工程请 register 真实 kind。
-- 常见坑：kind 与内建冲突；忘记在 fx.run handlers 合并路径可见（全局表 + merge）。
-- tabMachine 对照：无；偏自定义 effect 注册。
--
-- 仓库根：lua examples/fx_api/register.lua

package.path = "src/?.lua;examples/fx_api/?.lua;" .. package.path

local C = require("_common")
local Cont, fx, Coro
Cont, fx = C.Cont, C.fx
Coro = require("coro")

local M = {}

function M.run(opts)
  opts = opts or {}
  C.quiet = not not opts.quiet

  C.section("register 自定义 kind=greet")
  -- 先清掉以免污染其它用例
  pcall(fx.unregister, "greet")

  fx.register("greet", function(req)
    C.log("  [handler] greet name=%s", tostring(req.name))
    return { ok = true, hello = "hi " .. tostring(req.name) }
  end)

  local ma = Coro.yield({ kind = "greet", name = "binbin" }) >> function(res)
    return Cont.unit(res)
  end
  local r = fx.run(ma)
  C.need(r.ok and r.value.hello == "hi binbin")
  C.log("  hello=%s", r.value.hello)

  C.section("unregister 后未知 kind → Failed")
  fx.unregister("greet")
  local r2 = fx.run(Coro.yield({ kind = "greet", name = "x" }))
  C.need(r2.failed, "unknown kind should fail")
  C.log("  failed as expected: %s", tostring(r2.error and (r2.error.tag or r2.error)))

  if not C.quiet then C.ok("register") end
  return true
end

if arg and arg[0] and arg[0]:match("register%.lua$") then
  local quiet = arg[1] == "test" or arg[1] == "--quiet"
  M.run({ quiet = quiet })
  if quiet then C.ok("register") end
end

return M
