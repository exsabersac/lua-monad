-- FxUnityBootstrap.lua — 把注入的 Unity/Mock host 接到 fx.run opts.scheduler
--
-- 用法（xLua 启动脚本示例）：
--
--   package.path = "..../src/?.lua;..../host/unity/?.lua;" .. package.path
--
--   -- C# InjectIntoLua 已设置全局 UnityHost = { now, schedule, cancel [, schedule_real] }
--   local Boot = require("FxUnityBootstrap")
--   local api = Boot.bootstrap(UnityHost)
--   -- 或：api = Boot.bootstrap(UnityHost, { allow_real_time = false })
--
--   local Cont = require("cont")
--   local fx = require("fx")
--   local r = api.run(fx.wait(0.5) >> function(_) return Cont.unit("ok") end)
--   -- 等价于 fx.run(..., { scheduler = api.scheduler })
--
-- 无 Unity 本地验证：
--   local Mock = require("MockUnityHost")
--   local host = Mock.with_virtual()
--   local api = require("FxUnityBootstrap").bootstrap(host)
--   -- wait 需手动 pump：见 MockUnityHost / README

local LuaGameScheduler = require("LuaGameScheduler")

local M = {}

local function copy_opts(src)
  local o = {}
  if type(src) == "table" then
    for k, v in pairs(src) do
      o[k] = v
    end
  end
  return o
end

--- bootstrap(host, opts?) → api
-- opts.allow_real_time：传给后续 api.run（默认 false；游戏逻辑勿开）
-- opts.fx：可注入已 require 的 fx 模块（测试用）；默认 require("fx")
--
-- api 字段：
--   .host / .scheduler
--   .run(ma, handlers?, run_opts?)  — 自动填 opts.scheduler
--   .start_session(ma, handlers?, run_opts?) — 同上（经 fx.sched.start_session）
--   .adapt_opts(run_opts?) → 合并了 scheduler 的 opts 表
function M.bootstrap(host, opts)
  opts = opts or {}
  assert(type(host) == "table", "FxUnityBootstrap.bootstrap: host table required")

  local scheduler = LuaGameScheduler.adapt(host)
  local fx = opts.fx
  if fx == nil then
    fx = require("fx")
  end

  local api = {
    host = host,
    scheduler = scheduler,
    allow_real_time = not not opts.allow_real_time,
  }

  function api.adapt_opts(run_opts)
    local o = copy_opts(run_opts)
    if o.scheduler == nil then
      o.scheduler = scheduler
    end
    if o.allow_real_time == nil and api.allow_real_time then
      o.allow_real_time = true
    end
    return o
  end

  function api.run(ma, handlers, run_opts)
    return fx.run(ma, handlers, api.adapt_opts(run_opts))
  end

  function api.start_session(ma, handlers, run_opts)
    local h = handlers
    -- 与 fx.run 一致：合并 default + registry（若调用方未自行 merge，仍可直接传 overrides）
    if fx.sched and type(fx.sched.start_session) == "function" then
      local merge = fx.registry and fx.registry.merge_handlers
      local handlers2 = handlers
      if type(merge) == "function" and type(fx.default_handlers) == "table" then
        handlers2 = merge(fx.default_handlers, handlers)
      end
      return fx.sched.start_session(ma, handlers2, api.adapt_opts(run_opts))
    end
    error("FxUnityBootstrap: fx.sched.start_session unavailable")
  end

  return api
end

--- from_global(name?, opts?) — 读 _G[name or "UnityHost"] 再 bootstrap
function M.from_global(name, opts)
  name = name or "UnityHost"
  local host = rawget(_G, name)
  assert(type(host) == "table",
    "FxUnityBootstrap.from_global: _G." .. tostring(name) .. " must be host table")
  return M.bootstrap(host, opts)
end

return M
