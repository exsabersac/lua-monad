#!/usr/bin/env lua
-- fx_custom_handlers.lua — 同一管道，自定义 handlers：瞬时、记录事件、断言日志
-- 在仓库根目录执行：lua examples/fx_custom_handlers.lua

package.path = "src/?.lua;" .. package.path

local Cont = require("cont")
local fx = require("fx")
local print, assert, tostring = print, assert, tostring

-- 与 fx_wait_click_flow 同构的管道（略缩打印）
local flow = Cont.withEnv(function(_ENV)
  function open_ui(_)
    return Cont.unit({ ui = "login" })
  end
  function pause_brief(st)
    return fx.wait(0.05) >> function(_)
      return Cont.unit(st)
    end
  end
  function do_click(st)
    return fx.click("login") >> function(res)
      st.click = res
      return Cont.unit(st)
    end
  end
  function pause_again(st)
    return fx.wait(0.02) >> function(_)
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

local events = {}

local instant = {
  wait = function(req)
    events[#events + 1] = { kind = "wait", seconds = req.seconds }
    -- 不 busy-wait：测试/回放场景瞬时兑现
    return true
  end,
  click = function(req)
    events[#events + 1] = { kind = "click", target = req.target }
    return { ok = true, target = req.target, source = "custom" }
  end,
  connect = function(req)
    events[#events + 1] = { kind = "connect", host = req.host, opts = req.opts }
    return { ok = true, host = req.host, latency = 0, source = "custom" }
  end,
}

print("=== fx_custom_handlers：瞬时 handlers + 事件日志 ===")
local final = fx.run(flow(nil), instant)

assert(final.status == "ok")
assert(final.click.source == "custom")
assert(final.conn.source == "custom")

-- 事件序：wait → click → wait → connect
assert(#events == 4, "expected 4 events, got " .. #events)
assert(events[1].kind == "wait" and events[1].seconds == 0.05)
assert(events[2].kind == "click" and events[2].target == "login")
assert(events[3].kind == "wait" and events[3].seconds == 0.02)
assert(events[4].kind == "connect" and events[4].host == "api.example")
assert(events[4].opts and events[4].opts.tls == true)

for i, e in ipairs(events) do
  print(string.format("  event[%d] %s %s", i, e.kind,
    e.target or e.host or tostring(e.seconds)))
end

print("fx_custom_handlers OK")
