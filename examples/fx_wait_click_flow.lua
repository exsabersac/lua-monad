#!/usr/bin/env lua
-- fx_wait_click_flow.lua — Cont.withEnv 同步写法 + fx.wait/click/connect 异步效果
-- 在仓库根目录执行：lua examples/fx_wait_click_flow.lua
--
-- 模式：「同步写法 / 异步效果」
--   业务步骤在 withEnv 里顺序书写；wait/网络/点击通过 Coro.yield 交出请求，
--   由 fx.run 的外部解释器（默认 mock）兑现。非真实 UI/网络。

package.path = "src/?.lua;" .. package.path

local Cont = require("cont")
local fx = require("fx")
local print, assert, tostring = print, assert, tostring

local flow = Cont.withEnv(function(_ENV)
  function open_ui(_)
    print("  [step] open_ui")
    return Cont.unit({ ui = "login", t = 0 })
  end

  function pause_brief(st)
    print("  [step] wait(0.05) …")
    return fx.wait(0.05) >> function(_)
      st.t = (st.t or 0) + 1
      return Cont.unit(st)
    end
  end

  function do_click(st)
    print("  [step] click(\"login\")")
    return fx.click("login") >> function(res)
      st.click = res
      return Cont.unit(st)
    end
  end

  function pause_again(st)
    print("  [step] wait(0.02) …")
    return fx.wait(0.02) >> function(_)
      st.t = st.t + 1
      return Cont.unit(st)
    end
  end

  function do_connect(st)
    print("  [step] connect(\"api.example\")")
    return fx.connect("api.example") >> function(conn)
      st.conn = conn
      return Cont.unit(st)
    end
  end

  function done(st)
    print("  [step] done")
    st.status = "ok"
    return Cont.unit(st)
  end
end)

print("=== fx_wait_click_flow：默认 mock handlers（含短 busy-wait）===")
local result = fx.run(flow(nil))
assert(result.ok, "expected ok result")
local final = result.value
print("最终:", final.status, "clicks=", tostring(final.click and final.click.target),
  "host=", tostring(final.conn and final.conn.host), "waits=", tostring(final.t))
assert(final.status == "ok")
assert(final.click and final.click.ok and final.click.target == "login")
assert(final.conn and final.conn.ok and final.conn.host == "api.example")
assert(final.t == 2)

print("fx_wait_click_flow OK")
