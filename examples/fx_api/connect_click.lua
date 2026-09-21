#!/usr/bin/env lua
-- connect_click.lua — Sugar · fx.connect / fx.click 演示 handlers
--
-- 用途：教学用 mock 效果（默认 handlers 打印并返回 {ok,host/target}）。
-- 与 Core：工程请 fx.register 真实网络/UI kind；勿把 connect/click 当生产 API。
-- resume：handler 返回表。
-- 常见坑：默认 wait 仍可能 busy_wait——本例对 wait 用瞬时 handler 或 GameSim。
-- tabMachine 对照：无。
--
-- 仓库根：lua examples/fx_api/connect_click.lua

package.path = "src/?.lua;examples/fx_api/?.lua;" .. package.path

local C = require("_common")
local Cont, fx = C.Cont, C.fx

local M = {}

function M.run(opts)
  opts = opts or {}
  C.quiet = not not opts.quiet

  -- 瞬时 wait + 静默 connect/click，避免墙钟与默认 print
  local handlers = {
    wait = function(req)
      C.log("  [mock] wait %.3fs (instant)", req.seconds or 0)
      return true
    end,
    click = function(req)
      C.log("  [mock] click %s", tostring(req.target))
      return { ok = true, target = req.target }
    end,
    connect = function(req)
      C.log("  [mock] connect %s", tostring(req.host))
      return { ok = true, host = req.host, latency = 0.012 }
    end,
  }

  C.section("connect + click 管道（瞬时 wait）")
  local pipe = Cont.withEnv(function(_ENV)
    function open(_)
      return Cont.unit({ t = 0 })
    end
    function pause(st)
      return fx.wait(0.05) >> function(_)
        st.t = st.t + 1
        return Cont.unit(st)
      end
    end
    function do_click(st)
      return fx.click("login") >> function(res)
        st.click = res
        return Cont.unit(st)
      end
    end
    function do_connect(st)
      return fx.connect("api.example", { tls = true }) >> function(conn)
        st.conn = conn
        return Cont.unit(st)
      end
    end
    function done(st)
      st.status = "ok"
      return Cont.unit(st)
    end
  end)

  local r = fx.run(pipe(nil), handlers)
  C.need(r.ok)
  local st = r.value
  C.need(st.status == "ok" and st.t == 1)
  C.need(st.click and st.click.ok and st.click.target == "login")
  C.need(st.conn and st.conn.ok and st.conn.host == "api.example")
  C.log("  click=%s host=%s", st.click.target, st.conn.host)

  if not C.quiet then C.ok("connect_click") end
  return true
end

if arg and arg[0] and arg[0]:match("connect_click%.lua$") then
  local quiet = arg[1] == "test" or arg[1] == "--quiet"
  M.run({ quiet = quiet })
  if quiet then C.ok("connect_click") end
end

return M
