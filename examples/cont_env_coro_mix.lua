#!/usr/bin/env lua
-- cont_env_coro_mix.lua — withEnv 步骤中混入 Coro.yield，再用 start/resume 或 run 驱动
-- 在仓库根目录执行：lua examples/cont_env_coro_mix.lua
--
-- 澄清：
--   1. Coro.yield 是本库基于 Cont 的 CPS 挂起（答案类型 Done|Yielded），
--      不是 Lua 原生 coroutine.yield / coroutine.create。
--   2. Cont.withEnv 只负责把 env 上的步骤函数按定义序自动 >>；
--      挂起/恢复仍由 Coro.start、Coro.resume、Coro.run 完成。
--   3. body 参数名用 _ENV 才能让 `function name` 写入收集表；print 等先收成局部。

package.path = "src/?.lua;" .. package.path

local Cont = require("cont")
local Coro = require("coro")
local print, assert = print, assert

local pipe = Cont.withEnv(function(_ENV)
  -- 前：纯 Cont 预处理
  function prepare(x)
    print("  prepare:", x, "→", x + 1)
    return Cont.unit(x + 1)
  end

  -- 中：CPS 协程挂起，等外部 resume 的回复
  function ask(x)
    print("  ask: yield \"need-input\"（当前 x=", x, "）")
    return Coro.yield("need-input") >> function(reply)
      print("  ask: 收到 reply=", reply)
      return Cont.unit({ base = x, reply = reply })
    end
  end

  -- 后：再纯 Cont 收尾
  function finish(pair)
    local sum = pair.base + pair.reply
    print("  finish:", pair.base, "+", pair.reply, "=", sum)
    return Cont.unit(sum)
  end
end)

print("=== 用 Coro.start / resume 逐步驱动 ===")
local a1 = Coro.start(pipe(10))
assert(Coro.isYielded(a1))
assert(a1.value == "need-input")
print("第一次答案: Yielded", a1.value)

local a2 = Coro.resume(a1, 5) -- 用户输入 5
assert(Coro.isDone(a2))
print("最终 Done.value:", a2.value)
assert(a2.value == 16) -- prepare: 10→11；11+5=16

print("\n=== 用 Coro.run（handler 自动 resume）===")
local final = Coro.run(pipe(7), function(prompt)
  assert(prompt == "need-input")
  print("  handler 看到 prompt:", prompt, "→ 回答 3")
  return 3
end)
print("Coro.run 最终:", final)
assert(final == 11) -- prepare: 7→8；8+3=11

print("cont_env_coro_mix OK")
