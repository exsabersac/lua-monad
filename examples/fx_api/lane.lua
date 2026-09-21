#!/usr/bin/env lua
-- lane.lua — Sugar · fx.lane / lane_join / lane_stop / lanes
--
-- 用途：命名子流（session.lanes[name]）；可按名 join/stop/abort。
-- 与 Core：lane ≈ 命名 fork；lanes(map) ≈ 命名版 when_all（结果字典）。
-- 何时用 Sugar：需要按名字停/查子流；只要并行汇合用 when_all 即可。
-- 常见坑：同名覆盖；跨 session 的名字无效（跨会话用 proxy+flow）。
-- tabMachine 对照：c:start("t1") / 命名 join（无 Tab DSL）。
--
-- 仓库根：lua examples/fx_api/lane.lua

package.path = "src/?.lua;examples/fx_api/?.lua;" .. package.path

local C = require("_common")
local Cont, fx = C.Cont, C.fx

local M = {}

function M.run(opts)
  opts = opts or {}
  C.quiet = not not opts.quiet

  C.section("lane + lane_join")
  local r, sim = C.run_sim(
    fx.lane("worker", fx.wait(0.20) >> function(_) return Cont.unit(7) end) >> function(h)
      C.need(h and h.id, "lane returns handle")
      return fx.lane_join("worker") >> function(v)
        return Cont.unit(v)
      end
    end
  )
  C.need(r.ok and r.value == 7)
  C.need(sim:now() >= 0.20 - 1e-9)
  C.log("  joined=%s t=%.2f", tostring(r.value), sim:now())

  C.section("lanes 字典汇合")
  local r2, sim2 = C.run_sim(fx.lanes({
    a = fx.wait(0.15) >> function(_) return Cont.unit("A") end,
    b = fx.wait(0.25) >> function(_) return Cont.unit("B") end,
  }))
  C.need(r2.ok and r2.value.a == "A" and r2.value.b == "B")
  C.need(sim2:now() >= 0.25 - 1e-9 and sim2:now() < 0.40)
  C.log("  a=%s b=%s t=%.2f", r2.value.a, r2.value.b, sim2:now())

  C.section("lane_stop 合作停止")
  local r3 = select(1, C.run_sim(
    fx.lane("long", fx.wait(5.0) >> function(_) return Cont.unit("nope") end) >> function(_)
      return fx.lane_stop("long", "halt") >> function(ok)
        return Cont.unit(ok)
      end
    end
  ))
  C.need(r3.ok and r3.value == true)
  C.log("  lane_stop ok=%s", tostring(r3.value))

  if not C.quiet then C.ok("lane") end
  return true
end

if arg and arg[0] and arg[0]:match("lane%.lua$") then
  local quiet = arg[1] == "test" or arg[1] == "--quiet"
  M.run({ quiet = quiet })
  if quiet then C.ok("lane") end
end

return M
