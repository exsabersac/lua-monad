#!/usr/bin/env lua
-- fork_join.lua — Core · fx.fork / join / join_handles
--
-- 用途：非结构化并发——先 fork 拿到 handle，中间可做别的事，再 join。
-- 参数：fork(ma)→handle{id}；join(handle, opts?)；join_handles(handles, opts?)。
-- opts.cancel_siblings：一人完成后取消同批兄弟（join_handles）。
-- resume：子任务 Done 的值；子 Failed/Aborted 向 join 传播。
-- 与 when_all：when_all 一次结构化汇合；fork+join 可交错中间工作。
-- 常见坑：忘记 join 导致子任务仍跑但结果丢失；handle 跨 session 无效。
-- tabMachine 对照：近似 start + join（无命名时用 fork；有名用 lane）。
--
-- 仓库根：lua examples/fx_api/fork_join.lua

package.path = "src/?.lua;examples/fx_api/?.lua;" .. package.path

local C = require("_common")
local Cont, fx = C.Cont, C.fx

local M = {}

function M.run(opts)
  opts = opts or {}
  C.quiet = not not opts.quiet

  C.section("fork 两路 wait，中间 unit，再 join_handles（游戏时间≈max）")
  local pipe = fx.fork(fx.wait(0.30) >> function(_) return Cont.unit("A") end) >> function(h1)
    return fx.fork(fx.wait(0.50) >> function(_) return Cont.unit("B") end) >> function(h2)
      return Cont.unit(true) >> function(_)
        return fx.join_handles({ h1, h2 })
      end
    end
  end
  local r, sim = C.run_sim(pipe)
  C.need(r.ok and r.value[1] == "A" and r.value[2] == "B", "join vals")
  C.need(sim:now() >= 0.50 - 1e-9 and sim:now() < 0.65, "≈max not sum")
  C.log("  vals=%s,%s game_time=%.2f", r.value[1], r.value[2], sim:now())

  C.section("子 Failed → join 传播")
  local r2 = select(1, C.run_sim(
    fx.fork(fx.fail("child-boom")) >> function(h) return fx.join(h) end
  ))
  C.need(r2.failed and r2.error == "child-boom", "fail propagates")
  C.log("  error=%s", tostring(r2.error))

  if not C.quiet then C.ok("fork_join") end
  return true
end

if arg and arg[0] and arg[0]:match("fork_join%.lua$") then
  local quiet = arg[1] == "test" or arg[1] == "--quiet"
  M.run({ quiet = quiet })
  if quiet then C.ok("fork_join") end
end

return M
