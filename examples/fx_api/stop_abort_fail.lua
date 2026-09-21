#!/usr/bin/env lua
-- stop_abort_fail.lua — Core · fx.stop / abort / fail 终态
--
-- 用途：
--   stop(reason)  → Stopped：合作式结束；join/when_all 侧通常当取消/停止
--   abort(reason) → Aborted：异常中止；join/when_all 不算成功值，向 waiter 传播
--   fail(err)     → Failed：业务失败；可用 Cont.catch / fx.try 旁路
-- 与 Core：三者都是终态原语；fail 别名 throw。
-- 常见坑：把 abort 当 stop 用会导致并行汇合全盘失败；取消令牌仍走 Stopped。
-- tabMachine 对照：stop / abort / 失败路径（本库无 Tab DSL）。
--
-- 仓库根：lua examples/fx_api/stop_abort_fail.lua

package.path = "src/?.lua;examples/fx_api/?.lua;" .. package.path

local C = require("_common")
local Cont, fx = C.Cont, C.fx

local M = {}

function M.run(opts)
  opts = opts or {}
  C.quiet = not not opts.quiet

  C.section("fx.stop → stopped")
  local r1 = select(1, C.run_sim(fx.wait(0.05) >> function(_)
    return fx.stop("user-quit")
  end))
  C.need(r1.ok == false and r1.stopped and r1.reason == "user-quit", "stop shape")
  C.log("  stopped reason=%s", tostring(r1.reason))

  C.section("fx.abort → aborted（join 传播）")
  local r2, sim = C.run_sim(
    fx.fork(fx.wait(0.05) >> function(_)
      return fx.abort("child-boom")
    end) >> function(h)
      return fx.join(h)
    end
  )
  C.need(r2.aborted and r2.reason == "child-boom", "abort via join")
  C.log("  aborted reason=%s game_time=%.2f", tostring(r2.reason), sim:now())

  C.section("fx.fail → failed")
  local r3 = fx.run(fx.fail("boom"))
  C.need(r3.failed and r3.error == "boom", "fail shape")
  C.log("  failed error=%s", tostring(r3.error))

  C.section("fx.try 捕获 fail")
  local r4 = fx.try(fx.fail("x"), nil, {
    on_fail = function(err)
      return Cont.unit("recovered:" .. tostring(err))
    end,
  })
  C.need(r4.ok and r4.value == "recovered:x", "try on_fail")
  C.log("  try value=%s", tostring(r4.value))

  if not C.quiet then C.ok("stop_abort_fail") end
  return true
end

if arg and arg[0] and arg[0]:match("stop_abort_fail%.lua$") then
  local quiet = arg[1] == "test" or arg[1] == "--quiet"
  M.run({ quiet = quiet })
  if quiet then C.ok("stop_abort_fail") end
end

return M
