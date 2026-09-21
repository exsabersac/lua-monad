#!/usr/bin/env lua
-- proxy.lua — Sugar · fx.proxy / proxy_join / proxy_stop
--
-- 用途：外部引用已有 lane 名 / handle / flow，不拥有 Cont；可跨模块 wait/stop。
-- 与 Core：不启动任务；lane/fork 才启动。flow:proxy() 可跨 session（同 scheduler）。
-- 何时用：外部系统要等/停别人的流；同 session 内有名子流也可 proxy("name")。
-- 常见坑：proxy 未知名 → Failed(proxy_unknown)；误以为 proxy 会 fork。
-- tabMachine 对照：tabProxy 轻量子集（无完整代理树 / 事件转发）。
--
-- 仓库根：lua examples/fx_api/proxy.lua

package.path = "src/?.lua;examples/fx_api/?.lua;" .. package.path

local C = require("_common")
local Cont, fx = C.Cont, C.fx
local Sched = require("fx_sched")

local M = {}

function M.run(opts)
  opts = opts or {}
  C.quiet = not not opts.quiet

  C.section("同 session：lane 名 → proxy_join")
  local r, sim = C.run_sim(
    fx.lane("escort", fx.wait(0.20) >> function(_) return Cont.unit("arrived") end) >> function(_)
      return fx.proxy_join(fx.proxy("escort")) >> function(v)
        return Cont.unit(v)
      end
    end
  )
  C.need(r.ok and r.value == "arrived")
  C.log("  proxy_join=%s t=%.2f", tostring(r.value), sim:now())

  C.section("跨 session：flow:proxy + VirtualClock")
  local clock = C.Scheduler.VirtualClock()
  local host = Sched.start_session(
    fx.wait(0.15) >> function(_) return Cont.unit("done") end,
    {},
    { scheduler = clock }
  )
  local p = host:proxy()
  C.need(p._is_proxy and p.flow == host)
  local waiter = Sched.start_session(
    fx.proxy_join(p) >> function(v) return Cont.unit(v) end,
    {},
    { scheduler = clock }
  )
  clock.advance(0.20)
  C.need(host.done and host.result.ok)
  C.need(waiter.done and waiter.result.ok and waiter.result.value == "done")
  C.log("  cross-session value=%s", tostring(waiter.result.value))

  C.section("proxy_stop 停 host flow")
  clock = C.Scheduler.VirtualClock()
  host = Sched.start_session(
    fx.wait(5.0) >> function(_) return Cont.unit("x") end,
    {},
    { scheduler = clock }
  )
  local stopper = Sched.start_session(
    fx.proxy_stop(host:proxy(), "halt") >> function(ok) return Cont.unit(ok) end,
    {},
    { scheduler = clock }
  )
  C.need(stopper.done and stopper.result.ok and stopper.result.value == true)
  C.need(host.done and host.result.stopped and host.result.reason == "halt")
  C.log("  halted reason=%s", tostring(host.result.reason))

  if not C.quiet then C.ok("proxy") end
  return true
end

if arg and arg[0] and arg[0]:match("proxy%.lua$") then
  local quiet = arg[1] == "test" or arg[1] == "--quiet"
  M.run({ quiet = quiet })
  if quiet then C.ok("proxy") end
end

return M
