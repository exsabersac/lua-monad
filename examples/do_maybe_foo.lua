#!/usr/bin/env lua
-- do_maybe_foo.mdo — LYAH「foo」：Just 3 与 Just "!" 拼成 "3!"
-- 推荐直接跑：lua tools/mdo.lua --run examples/do_maybe_foo.mdo
-- 或生成 .lua：lua tools/mdo.lua examples/do_maybe_foo.mdo 再 lua examples/do_maybe_foo.lua

package.path = "src/?.lua;" .. package.path

local Maybe = require("maybe")

-- 对照 Haskell：
--   foo = do
--     x <- Just 3
--     y <- Just "!"
--     Just (show x ++ y)

local foo = Maybe.Just(3) >> function(x)
return Maybe.Just("!") >> function(y)
return Maybe.Just(tostring(x) .. y)
end
end

assert(Maybe.isJust(foo), "foo should be Just")
assert(foo.value == "3!", "foo value")
print('foo => Just "' .. foo.value .. '"')
