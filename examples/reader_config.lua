#!/usr/bin/env lua
-- reader_config.lua — Reader：ask / asks / localEnv 读配置
-- 在仓库根目录：lua examples/reader_config.lua

package.path = "src/?.lua;" .. package.path

local Reader = require("reader")

print("=== Reader（配置 / 依赖注入）===")

local cfg = {
  host = "localhost",
  port = 8080,
  debug = true,
}

-- ask：读完整环境
local who = Reader.ask() >> function(env)
  return Reader.unit(env.host .. ":" .. tostring(env.port))
end
print("ask → endpoint:", Reader.runReader(who, cfg))

-- asks：投影字段
local port_only = Reader.asks(function(e) return e.port end)
print("asks(.port):", Reader.runReader(port_only, cfg))

-- localEnv：在「改造后的环境」里跑子计算（不改外层）
local with_prod = Reader.localEnv(function(e)
  return {
    host = "prod.example.com",
    port = e.port,
    debug = false,
  }
end, who)

print("localEnv(prod) →", Reader.runReader(with_prod, cfg))
print("原 cfg 未变 host=", cfg.host)

-- 链式：asks + bind
local greeting = Reader.asks(function(e) return e.debug end) >> function(dbg)
  return Reader.ask() >> function(env)
    local msg = "serving on " .. env.host
    if dbg then msg = msg .. " [debug]" end
    return Reader.unit(msg)
  end
end
print("greeting:", Reader.runReader(greeting, cfg))
