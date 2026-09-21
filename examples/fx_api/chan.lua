#!/usr/bin/env lua
-- chan.lua — Core · fx.chan / send / recv / close / is_closed
--
-- 用途：有界 mailbox；满则 send 挂起，空则 recv 挂起；close 后 recv 得约定终值。
-- 参数：chan(capacity≥0 整数，默认 1)；send(ch,v)；recv(ch)；close(ch)。
-- yield kinds：chan_send / chan_recv / chan_close。
-- 常见坑：capacity=0 纯同步会合；忘记 close 导致 recv 永挂；跨 session 共用 ch 需同 scheduler。
-- tabMachine 对照：近似 mailbox / 通道（无 Tab DSL）。
--
-- 仓库根：lua examples/fx_api/chan.lua

package.path = "src/?.lua;examples/fx_api/?.lua;" .. package.path

local C = require("_common")
local Cont, fx = C.Cont, C.fx

local M = {}

function M.run(opts)
  opts = opts or {}
  C.quiet = not not opts.quiet

  C.section("chan(1)：先 recv 挂起，再 send 兑现")
  local sim = C.new_sim()
  local ch = fx.chan(1)
  local got
  local consumer = sim:start_flow(nil,
    fx.recv(ch) >> function(v)
      got = v
      return Cont.unit(v)
    end
  )
  C.need(not consumer.done)
  local producer = sim:start_flow(nil, fx.send(ch, "mail"))
  sim:tick(0)
  C.need(consumer.done and producer.done and got == "mail")
  C.need(sim:now() == 0)
  C.log("  mailbox value=%s", tostring(got))

  C.section("close + is_closed")
  local ch2 = fx.chan(1)
  C.need(not fx.is_closed(ch2))
  local r = select(1, C.run_sim(fx.close(ch2) >> function(_)
    return Cont.unit(fx.is_closed(ch2))
  end))
  C.need(r.ok and r.value == true, "closed")
  C.log("  is_closed=%s", tostring(r.value))

  C.section("背压：capacity=1，缓冲满后第二发需等 recv")
  -- 单 session 内：先塞满再挂起第二次 send，并行 recv 释放
  sim = C.new_sim()
  ch = fx.chan(1)
  local r3, sim3 = C.run_sim(
    fx.when_all({
      -- 生产者：两发
      fx.send(ch, 1) >> function(_)
        return fx.send(ch, 2) >> function(_)
          return Cont.unit("sent")
        end
      end,
      -- 消费者：两收（给一点游戏时间交错）
      fx.wait(0.05) >> function(_)
        return fx.recv(ch) >> function(a)
          return fx.recv(ch) >> function(b)
            return Cont.unit({ a, b })
          end
        end
      end,
    })
  )
  C.need(r3.ok, "when_all backpressure")
  C.need(r3.value[1] == "sent")
  C.need(r3.value[2][1] == 1 and r3.value[2][2] == 2)
  C.log("  got=%s,%s t=%.2f", tostring(r3.value[2][1]), tostring(r3.value[2][2]), sim3:now())

  if not C.quiet then C.ok("chan") end
  return true
end

if arg and arg[0] and arg[0]:match("chan%.lua$") then
  local quiet = arg[1] == "test" or arg[1] == "--quiet"
  M.run({ quiet = quiet })
  if quiet then C.ok("chan") end
end

return M
