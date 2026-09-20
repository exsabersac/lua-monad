#!/usr/bin/env lua
-- do_walk_the_line.mdo — LYAH Walk the line routine，用 @mdo 写法
-- 目标：Just (3,2)
-- 编辑后：lua tools/mdo.lua examples/do_walk_the_line.mdo

package.path = "src/?.lua;" .. package.path

local Maybe = require("maybe")

local function showPole(pole)
  return string.format("(%d,%d)", pole[1], pole[2])
end

local function showMaybePole(mp)
  if Maybe.isNothing(mp) then
    return "Nothing"
  end
  return "Just " .. showPole(mp.value)
end

-- landLeft / landRight：落鸟；两侧相差 ≥ 4 则 Nothing
local function landLeft(n)
  return function(pole)
    local left, right = pole[1], pole[2]
    if math.abs((left + n) - right) < 4 then
      return Maybe.Just({ left + n, right })
    else
      return Maybe.Nothing()
    end
  end
end

local function landRight(n)
  return function(pole)
    local left, right = pole[1], pole[2]
    if math.abs(left - (right + n)) < 4 then
      return Maybe.Just({ left, right + n })
    else
      return Maybe.Nothing()
    end
  end
end

-- 对照 Haskell：
--   routine = do
--     start  <- return (0,0)
--     first  <- landLeft 2 start
--     second <- landRight 2 first
--     landLeft 1 second

local routine = Maybe.Just({ 0, 0 }) >> function(start)
return landLeft(2)(start) >> function(first)
return landRight(2)(first) >> function(second)
return landLeft(1)(second)
end
end
end

print("routine => " .. showMaybePole(routine))
assert(Maybe.isJust(routine), "routine should be Just")
assert(routine.value[1] == 3 and routine.value[2] == 2, "routine pole (3,2)")
print("断言通过：Just (3,2)")
