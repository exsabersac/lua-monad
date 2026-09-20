#!/usr/bin/env lua
-- cont_env_local_helpers.lua — 步内 local 助手 vs 误挂到 env 的对比
-- 在仓库根目录执行：lua examples/cont_env_local_helpers.lua
--
-- 规则：挂到 env 的**函数**一律成为管道步骤。助手请写在步内 local function；
-- 配置用非函数字段。

package.path = "src/?.lua;" .. package.path

local Cont = require("cont")
local print, assert, math = print, assert, math

-- ---------- 正确：步内 local helpers + env 上非函数配置 ----------
local good = Cont.withEnv(function(_ENV)
  -- 非函数：不进管道
  scale = 2
  offset = 1

  function process(x)
    -- 多个 local 助手：不会被收集为步骤
    local function clamp01(n)
      if n < 0 then return 0 end
      if n > 1 then return 1 end
      return n
    end
    local function blend(a, b)
      return a * 0.7 + b * 0.3
    end

    local t = clamp01(x)
    local mixed = blend(t, 0.5)
    local out = mixed * scale + offset
    print("  [process] x=", x, "→ clamp", t, "blend", mixed, "out", out)
    return Cont.unit(out)
  end

  function round_step(v)
    local function nearest(n)
      return math.floor(n + 0.5)
    end
    local r = nearest(v)
    print("  [round_step]", v, "→", r)
    return Cont.unit(r)
  end
end)

print("=== 正确：local helpers；管道只有 process → round_step ===")
local g = Cont.evalCont(good(0.8))
-- clamp 0.8, blend 0.8*0.7+0.5*0.3=0.56+0.15=0.71, *2+1=2.42 → round 2
print("结果:", g)
assert(g == 2)

-- ---------- 警示：若把 helper 挂到 env，它会变成额外步骤 ----------
-- 下面演示「错误」写法的后果（对照正确写法；实际项目请用上面的 local）。
print("\n=== 错误示范：helper 挂到 env → 多出一个管道步骤 ===")
local bad = Cont.withEnv(function(_ENV)
  function helper(x)
    -- 本意是内部工具，却被收集成步骤！
    print("  [helper 被当成步骤跑了]", x)
    return Cont.unit(x + 100)
  end
  function main(x)
    print("  [main]", x)
    return Cont.unit(x * 2)
  end
end)
-- 顺序：helper → main；输入 3 → helper 103 → main 206（而非期望的 6）
local b = Cont.evalCont(bad(3))
print("误挂 helper 后 evalCont(3):", b, "（期望若仅 main 则为 6）")
assert(b == 206)

print("\n警告：助手勿 function 到 env；用步内 local function。")
print("cont_env_local_helpers OK")
