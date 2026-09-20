#!/usr/bin/env lua
-- cont_env_data_driven.lua — env 上放配置字段（非函数）+ 步骤闭包读配置
-- 在仓库根目录执行：lua examples/cont_env_data_driven.lua
--
-- 非函数赋值不进管道；步骤通过闭包 / _ENV 在运行时读配置。
-- 参数必须叫 _ENV，`function clamp` 才会写入收集表（若叫 env，则 function clamp
-- 会落到 chunk 全局，管道为空）。读配置用 env 别名或直接读 threshold 字段均可。

package.path = "src/?.lua;" .. package.path

local Cont = require("cont")
local print, assert = print, assert

local pipe = Cont.withEnv(function(_ENV)
  -- 配置字段：不是步骤（非函数赋值）
  threshold = 10
  label = "score"

  -- 步骤：运行 pipe(x) 时再读 threshold / label（通过 _ENV）
  function clamp(x)
    local t = threshold
    if x > t then
      print("  clamp:", x, "> threshold", t, "→", t)
      return Cont.unit(t)
    end
    print("  clamp:", x, "≤", t, "保持")
    return Cont.unit(x)
  end

  function scale(x)
    local out = x * 2
    print("  scale:", x, "→", out)
    return Cont.unit(out)
  end

  function tag(x)
    local labeled = { n = x, label = label }
    print("  tag:", labeled.label, "=", labeled.n)
    return Cont.unit(labeled)
  end

  -- label 可在步骤定义之后再改：步骤在 pipe(x) 运行时读取
  label = "score"
end)

print("=== 低于阈值：clamp 不截断 ===")
local r1 = Cont.evalCont(pipe(4))
print("结果:", r1.label, r1.n)
assert(r1.label == "score" and r1.n == 8) -- clamp 4 → scale 8 → tag

print("\n=== 高于阈值：clamp 截到 10 再 scale ===")
local r2 = Cont.evalCont(pipe(25))
print("结果:", r2.label, r2.n)
assert(r2.label == "score" and r2.n == 20) -- clamp 25→10 → scale 20 → tag

print("\n=== 显式 env 别名（闭包捕获同一表）===")
-- 与文档 pattern 对齐：先拿到 env 引用，再 env.clamp = function ... 注册步骤
local pipe_hi = Cont.withEnv(function(env)
  env.threshold = 100
  env.label = "hi-score"
  -- 不能写 function clamp：参数不叫 _ENV 时会落到全局；改用赋值
  env.clamp = function(x)
    local t = env.threshold
    if x > t then
      return Cont.unit(t)
    end
    return Cont.unit(x)
  end
  env.tag = function(x)
    return Cont.unit({ n = x, label = env.label })
  end
end)
local r3 = Cont.evalCont(pipe_hi(25))
assert(r3.n == 25 and r3.label == "hi-score")
print("threshold=100 时 25 不被截:", r3.n, r3.label)

print("cont_env_data_driven OK")
