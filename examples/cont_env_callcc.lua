#!/usr/bin/env lua
-- cont_env_callcc.lua — withEnv 管道 + Cont.callCC 提前中止
-- 在仓库根目录执行：lua examples/cont_env_callcc.lua
--
-- 要点：callCC 包住整条 pipe(x)；某步里调用 escape(...) 会跳过后续步骤，
-- 直接把值交给 callCC 外层续延（abort 风格）。withEnv 只负责按定义序 >>。
--
-- 注意：withEnv 的 body 参数若命名为 _ENV，则内部自由名走该表；
-- 因此把 type/print 收成 chunk 局部，供步骤闭包作 upvalue。

package.path = "src/?.lua;" .. package.path

local Cont = require("cont")
local type, print = type, print

-- 业务管道：validate → transform → finalize
-- escape 由外层 callCC 注入，供 validate 在拒绝时跳出整条链
local function make_pipeline(escape)
  return Cont.withEnv(function(_ENV)
    -- 校验：负数则 escape，后续 transform/finalize 不会跑
    function validate(n)
      if type(n) ~= "number" then
        return escape({ ok = false, reason = "not-a-number", input = n })
      end
      if n < 0 then
        print("  validate: 拒绝负数", n, "→ escape")
        return escape({ ok = false, reason = "negative", input = n })
      end
      print("  validate: 通过", n)
      return Cont.unit(n)
    end

    -- 变换：加倍
    function transform(n)
      local out = n * 2
      print("  transform:", n, "→", out)
      return Cont.unit(out)
    end

    -- 收尾：打成结果表
    function finalize(n)
      print("  finalize:", n)
      return Cont.unit({ ok = true, value = n })
    end
  end)
end

local function run(x)
  return Cont.callCC(function(escape)
    local pipe = make_pipeline(escape)
    return pipe(x)
  end)
end

print("=== 成功路径：evalCont(run(5)) ===")
local ok = Cont.evalCont(run(5))
print("结果:", ok.ok, "value=", ok.value)
assert(ok.ok == true and ok.value == 10) -- (5*2)

print("\n=== 中止路径：evalCont(run(-3)) ===")
local bad = Cont.evalCont(run(-3))
print("结果:", bad.ok, "reason=", bad.reason, "input=", bad.input)
assert(bad.ok == false and bad.reason == "negative" and bad.input == -3)

print("\n=== 中止路径：非数字 ===")
local nan = Cont.evalCont(run("x"))
assert(nan.ok == false and nan.reason == "not-a-number")
print("结果:", nan.ok, "reason=", nan.reason)

print("cont_env_callcc OK")
