#!/usr/bin/env lua
-- wait_real.lua — Sugar · fx.wait_real：墙钟等待（opt-in）
--
-- 用途：真实墙钟延迟（网络 SDK / 非游戏逻辑）；默认业务请用 fx.wait + 游戏时间。
-- 参数：seconds；yield kind="wait_real"。
-- 兑现路径：scheduler.schedule_real，或 opts.allow_real_time（busy_wait）；否则 Failed(wait_real_unsupported)。
-- 与 Core：wait 才是游戏主线；wait_real 是 Sugar / 工程逃生口。
-- 常见坑：在 GameSim 里误用 wait_real —— pause/慢放不会影响墙钟。
-- tabMachine 对照：无直接对应；偏宿主实时定时器。
--
-- 仓库根：lua examples/fx_api/wait_real.lua

package.path = "src/?.lua;examples/fx_api/?.lua;" .. package.path

local C = require("_common")
local Cont, fx = C.Cont, C.fx
local Sched = require("fx_sched")

local M = {}

function M.run(opts)
  opts = opts or {}
  C.quiet = not not opts.quiet

  ------------------------------------------------------------
  -- 1. 无 allow_real_time / schedule_real → Failed
  ------------------------------------------------------------
  C.section("wait_real 无 opt-in → Failed(wait_real_unsupported)")
  local r1 = fx.run(fx.wait_real(0.01))
  C.need(r1.ok == false and r1.failed, "should fail")
  local err = r1.error
  C.need(type(err) == "table" and err.tag == "wait_real_unsupported",
    "tag wait_real_unsupported")
  C.log("  error.tag=%s", tostring(err.tag))

  ------------------------------------------------------------
  -- 2. 宿主提供 schedule_real（推荐工程路径；此处同步回调模拟）
  ------------------------------------------------------------
  C.section("wait_real + scheduler.schedule_real（mock 立即回调）")
  local pending = {}
  local mock = {
    now = function() return 0 end,
    schedule = function(_d, _cb) return { cancelled = false } end,
    cancel = function(h) if h then h.cancelled = true end end,
    schedule_real = function(delay, cb)
      C.log("  schedule_real delay=%.3f", delay or 0)
      local h = { cancelled = false }
      pending[#pending + 1] = { h = h, cb = cb }
      return h
    end,
  }
  local flow = Sched.start_session(fx.wait_real(0.2) >> function(ok)
    return Cont.unit(ok)
  end, {}, { scheduler = mock })
  C.need(not flow.done and #pending == 1, "parked on schedule_real")
  -- 模拟墙钟到期
  local item = pending[1]
  if not item.h.cancelled then
    item.cb()
  end
  C.need(flow.done and flow.result.ok and flow.result.value == true,
    "schedule_real resume")
  C.log("  resumed via schedule_real")

  ------------------------------------------------------------
  -- 3. allow_real_time：走 busy_wait（沙箱里 sleep 可能是 no-op，只断言结果）
  ------------------------------------------------------------
  C.section("wait_real + allow_real_time → ok（不强制墙钟时长）")
  local r3 = fx.run(fx.wait_real(0.01), nil, { allow_real_time = true })
  C.need(r3.ok and r3.value == true, "allow_real_time should succeed")
  C.log("  allow_real_time ok (busy_wait 路径)")

  if not C.quiet then C.ok("wait_real") end
  return true
end

if arg and arg[0] and arg[0]:match("wait_real%.lua$") then
  local quiet = arg[1] == "test" or arg[1] == "--quiet"
  M.run({ quiet = quiet })
  if quiet then C.ok("wait_real") end
end

return M
