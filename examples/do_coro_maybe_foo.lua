#!/usr/bin/env lua
-- do_coro_maybe_foo.lua — LYAH「foo」，用 runDo/perform 顺序写，无需手写 >>
-- 在仓库根目录：lua examples/do_coro_maybe_foo.lua
--
-- 对照 @mdo / 手写 bind：
--   foo = do
--     x <- Just 3
--     y <- Just "!"
--     Just (show x ++ y)

package.path = "src/?.lua;" .. package.path

local Maybe = require("maybe")
local do_coro = require("do_coro")
local perform = do_coro.perform

local foo = Maybe.runDo(function()
  local x = perform(Maybe.Just(3))
  local y = perform(Maybe.Just("!"))
  return Maybe.Just(tostring(x) .. y)
end)

assert(Maybe.isJust(foo), "foo should be Just")
assert(foo.value == "3!", "foo value")
print('foo => Just "' .. foo.value .. '"')
