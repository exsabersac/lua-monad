#!/usr/bin/env lua
-- cont_env_fact_pipeline.lua — 较长算术/CPS 链：normalize → 分解平方 → 求和；
-- 另含阶乘风格步骤，以及对整条 pipe 结果做 mapCont。
-- 在仓库根目录执行：lua examples/cont_env_fact_pipeline.lua

package.path = "src/?.lua;" .. package.path

local Cont = require("cont")
local print, assert, type, math = print, assert, type, math

-- ---------- 1) 向量式：normalize → square_parts → sum_parts ----------
local vec_pipe = Cont.withEnv(function(_ENV)
  -- 规范化：保证是 {a,b} 表；若传入数字则当成 {n, n+1}
  function normalize(x)
    if type(x) == "number" then
      print("  normalize: 数字", x, "→ 配对", x, x + 1)
      return Cont.unit({ x, x + 1 })
    end
    print("  normalize: 已是对", x[1], x[2])
    return Cont.unit(x)
  end

  -- 各分量平方
  function square_parts(pair)
    local a2, b2 = pair[1] * pair[1], pair[2] * pair[2]
    print("  square_parts:", pair[1], "^2 +", pair[2], "^2 →", a2, b2)
    return Cont.unit({ a2, b2 })
  end

  function sum_parts(sq)
    local s = sq[1] + sq[2]
    print("  sum_parts:", sq[1], "+", sq[2], "=", s)
    return Cont.unit(s)
  end
end)

print("=== 向量管道：3 → {3,4} → 9+16 = 25 ===")
local hyp2 = Cont.evalCont(vec_pipe(3))
print("evalCont:", hyp2)
assert(hyp2 == 25)

print("\n=== 对整条结果 mapCont（答案 +1）===")
local mapped = Cont.mapCont(function(r)
  return r + 1
end, vec_pipe({ 3, 4 }))
print("mapCont(+1):", Cont.evalCont(mapped))
assert(Cont.evalCont(mapped) == 26)

-- ---------- 2) 阶乘风格：env 步骤里递归 Cont，再附带后处理 ----------
local fact_pipe = Cont.withEnv(function(_ENV)
  function to_n(x)
    assert(type(x) == "number" and x >= 0)
    return Cont.unit(math.floor(x))
  end

  -- 单步内递归 Cont 算阶乘
  function factorial(n)
    local function fact(k)
      if k <= 1 then
        return Cont.unit(1)
      end
      return fact(k - 1) >> function(r)
        return Cont.unit(k * r)
      end
    end
    print("  factorial: 计算", n, "!")
    return fact(n)
  end

  function annotate(v)
    return Cont.unit({ fact = v, note = "n!" })
  end
end)

print("\n=== 阶乘管道：5 → 120 → 注解表 ===")
local fr = Cont.evalCont(fact_pipe(5))
print("结果:", fr.note, fr.fact)
assert(fr.fact == 120 and fr.note == "n!")

print("cont_env_fact_pipeline OK")
