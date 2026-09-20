#!/usr/bin/env lua
-- cont_env_pipe.lua — Cont.withEnv 默认收集步骤并自动 >> 组合
-- 在仓库根目录执行：lua examples/cont_env_pipe.lua

package.path = "src/?.lua;" .. package.path

local Cont = require("cont")
-- 也可 require("cont_env")；Cont.withEnv 会延迟加载或由 cont_env 挂载

local pipe = Cont.withEnv(function(_ENV)
  function add1(x)
    return Cont.unit(x + 1)
  end
  function times2(x)
    return Cont.unit(x * 2)
  end
end)

local v = Cont.evalCont(pipe(3))
print("(3+1)*2 via withEnv:", v)
assert(v == 8)

-- 同名再定义：原地替换，仍保持首次出现次序
local pipe2 = Cont.withEnv(function(_ENV)
  function add1(x)
    return Cont.unit(x + 1)
  end
  function times2(x)
    return Cont.unit(x * 2)
  end
  -- 覆盖 add1：仍先于 times2
  function add1(x)
    return Cont.unit(x + 10)
  end
end)
assert(Cont.evalCont(pipe2(3)) == 26) -- (3+10)*2
print("redefine add1 in place:", Cont.evalCont(pipe2(3)))

-- 空环境 ≡ Cont.unit
local id = Cont.withEnv(function(_ENV) end)
assert(Cont.evalCont(id(42)) == 42)
print("empty env identity:", Cont.evalCont(id(42)))

print("cont_env_pipe OK")
