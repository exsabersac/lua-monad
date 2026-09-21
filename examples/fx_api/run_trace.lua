#!/usr/bin/env lua
-- run_trace.lua — Core · fx.run / set_tracer / get_tracer
--
-- 用途：
--   run(ma, handlers?, opts?) → 结构化结果表 {ok,value|stopped|failed|…}
--   set_tracer(fn) 全局追踪；opts.trace 亦可传 session 级。
-- resume/结果：见 docs/异步效果同步写法.md。
-- 常见坑：忘记注入 scheduler 导致 wait busy_wait；tracer 勿抛错。
-- tabMachine 对照：无；偏调试钩子。
--
-- 仓库根：lua examples/fx_api/run_trace.lua

package.path = "src/?.lua;examples/fx_api/?.lua;" .. package.path

local C = require("_common")
local Cont, fx = C.Cont, C.fx

local M = {}

function M.run(opts)
  opts = opts or {}
  C.quiet = not not opts.quiet

  C.section("fx.run + set_tracer 收集事件")
  local events = {}
  local prev = fx.get_tracer()
  fx.set_tracer(function(ev)
    events[#events + 1] = ev.type or "?"
    if not C.quiet and ev.type then
      C.log("  trace: %s kind=%s", tostring(ev.type), tostring(ev.kind))
    end
  end)

  local ok, err = pcall(function()
    local r, sim = C.run_sim(
      fx.wait(0.10) >> function(_) return Cont.unit(42) end
    )
    C.need(r.ok and r.value == 42)
    C.need(#events > 0, "tracer should see events")
    local joined = table.concat(events, ",")
    C.need(joined:find("yield", 1, true) or joined:find("done", 1, true),
      "expect yield/done in " .. joined)
    C.log("  events(%d)=%s t=%.2f", #events, joined, sim:now())
  end)

  fx.set_tracer(prev) -- 恢复
  if not ok then error(err) end

  C.section("fx.run 直接 Failed 结果表")
  local r2 = fx.run(fx.fail("nope"))
  C.need(r2.failed and r2.error == "nope")
  C.log("  failed ok")

  if not C.quiet then C.ok("run_trace") end
  return true
end

if arg and arg[0] and arg[0]:match("run_trace%.lua$") then
  local quiet = arg[1] == "test" or arg[1] == "--quiet"
  M.run({ quiet = quiet })
  if quiet then C.ok("run_trace") end
end

return M
