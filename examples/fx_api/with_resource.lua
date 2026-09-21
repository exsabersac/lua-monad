#!/usr/bin/env lua
-- with_resource.lua — Core · fx.with_resource（bracket 别名）
--
-- 用途：获取 → 使用 → 无论成功/失败/停止都释放（Cont.bracket）。
-- 参数：acquire()→Cont res；use(res)→Cont a；release(res, outcome?)→Cont _。
-- 与 Core：资源安全；不 yield 专用 kind，纯 Cont 组合。
-- 常见坑：release 里再挂起需能被外层 session 驱动；acquire 失败则不调 use/release。
-- tabMachine 对照：近似 finally / 资源守卫。
--
-- 仓库根：lua examples/fx_api/with_resource.lua

package.path = "src/?.lua;examples/fx_api/?.lua;" .. package.path

local C = require("_common")
local Cont, fx = C.Cont, C.fx

local M = {}

function M.run(opts)
  opts = opts or {}
  C.quiet = not not opts.quiet

  C.section("成功路径：acquire → use → release")
  local log = {}
  local r = fx.run(fx.with_resource(
    function()
      log[#log + 1] = "acq"
      return Cont.unit({ id = "sock" })
    end,
    function(res)
      log[#log + 1] = "use:" .. res.id
      return Cont.unit("ok")
    end,
    function(res)
      log[#log + 1] = "rel:" .. res.id
      return Cont.unit(true)
    end
  ))
  C.need(r.ok and r.value == "ok")
  C.need(table.concat(log, ",") == "acq,use:sock,rel:sock")
  C.log("  log=%s", table.concat(log, ","))

  C.section("use 内 fail：仍 release")
  log = {}
  local r2 = fx.run(fx.with_resource(
    function()
      log[#log + 1] = "acq"
      return Cont.unit({ id = "f" })
    end,
    function(_res)
      log[#log + 1] = "use"
      return fx.fail("boom")
    end,
    function(res)
      log[#log + 1] = "rel:" .. res.id
      return Cont.unit(true)
    end
  ))
  C.need(r2.failed and r2.error == "boom")
  C.need(table.concat(log, ",") == "acq,use,rel:f")
  C.log("  log=%s (release after fail)", table.concat(log, ","))

  -- 别名
  C.need(fx.bracket == fx.with_resource, "bracket alias")

  if not C.quiet then C.ok("with_resource") end
  return true
end

if arg and arg[0] and arg[0]:match("with_resource%.lua$") then
  local quiet = arg[1] == "test" or arg[1] == "--quiet"
  M.run({ quiet = quiet })
  if quiet then C.ok("with_resource") end
end

return M
