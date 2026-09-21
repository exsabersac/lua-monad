#!/usr/bin/env lua
-- supervise.lua — Core · fx.supervise：失败重启监督
--
-- 用途：子 Cont Failed（可选 Stopped）时按策略重启，直至成功或耗尽次数。
-- 参数：ma；opts.max_restarts（默认 3）、backoff（秒）、restart_if(err)、on_fail(err)、restart_on_stop。
-- resume：最终成功值；耗尽则 Failed。
-- 常见坑：无条件重启死循环业务错误；backoff 在游戏时间下才有意义。
-- tabMachine 对照：无直接 DSL；偏宿主监督树思想。
--
-- 仓库根：lua examples/fx_api/supervise.lua

package.path = "src/?.lua;examples/fx_api/?.lua;" .. package.path

local C = require("_common")
local Cont, fx = C.Cont, C.fx

local M = {}

function M.run(opts)
  opts = opts or {}
  C.quiet = not not opts.quiet

  C.section("首次 Failed，重启一次后成功")
  local attempts = 0
  local body = Cont.unit(true) >> function(_)
    attempts = attempts + 1
    if attempts == 1 then
      C.log("  attempt#%d → fail", attempts)
      return fx.fail("jitter")
    end
    C.log("  attempt#%d → ok", attempts)
    return Cont.unit("recovered")
  end

  local r, sim = C.run_sim(fx.supervise(body, {
    max_restarts = 1,
    backoff = 0.05,
    on_fail = function(err)
      C.log("  on_fail err=%s", tostring(err))
    end,
  }))
  C.need(r.ok and r.value == "recovered")
  C.need(attempts == 2)
  C.need(sim:now() >= 0.05 - 1e-9)
  C.log("  value=%s attempts=%d t=%.2f", tostring(r.value), attempts, sim:now())

  C.section("耗尽 max_restarts → Failed")
  attempts = 0
  local always = Cont.unit(true) >> function(_)
    attempts = attempts + 1
    return fx.fail("nope")
  end
  local r2 = select(1, C.run_sim(fx.supervise(always, { max_restarts = 2, backoff = 0 })))
  C.need(r2.failed and attempts == 3) -- 1 初次 + 2 重启
  C.log("  failed after attempts=%d err=%s", attempts, tostring(r2.error))

  if not C.quiet then C.ok("supervise") end
  return true
end

if arg and arg[0] and arg[0]:match("supervise%.lua$") then
  local quiet = arg[1] == "test" or arg[1] == "--quiet"
  M.run({ quiet = quiet })
  if quiet then C.ok("supervise") end
end

return M
