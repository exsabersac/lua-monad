#!/usr/bin/env lua
-- Walk the line — Learn You a Haskell 《A Fistful of Monads》
-- https://learnyouahaskell.github.io/a-fistful-of-monads.html
-- 用本库的 Maybe + 元表糖（>> / ..）复现 Pierre 走钢丝示例。

package.path = "src/?.lua;" .. package.path

local Maybe = require("maybe")

-- type Birds = Int
-- type Pole = (Birds, Birds)  →  { left, right }

local function showPole(pole)
  return string.format("(%d,%d)", pole[1], pole[2])
end

local function showMaybePole(mp)
  if Maybe.isNothing(mp) then
    return "Nothing"
  end
  return "Just " .. showPole(mp.value)
end

-- landLeft :: Birds -> Pole -> Maybe Pole
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

-- landRight :: Birds -> Pole -> Maybe Pole
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

-- banana :: Pole -> Maybe Pole
local function banana(_pole)
  return Maybe.Nothing()
end

local function say(label, mp)
  print(label)
  print("  => " .. showMaybePole(mp))
end

print("=== 单步着陆 ===")
say("landLeft 2 (0,0)", landLeft(2)({ 0, 0 }))
say("landLeft 10 (0,3)", landLeft(10)({ 0, 3 }))

print("\n=== >>= 链式（成功）===")
-- return (0,0) >>= landRight 2 >>= landLeft 2 >>= landRight 2
-- Just (2,4)
local ok = Maybe.Just({ 0, 0 })
  >> landRight(2)
  >> landLeft(2)
  >> landRight(2)
say("return (0,0) >>= landRight 2 >>= landLeft 2 >>= landRight 2", ok)

print("\n=== >>= 链式（中途失衡 → Nothing）===")
-- return (0,0) >>= landLeft 1 >>= landRight 4 >>= landLeft (-1) >>= landRight (-2)
-- Nothing
local fail = Maybe.Just({ 0, 0 })
  >> landLeft(1)
  >> landRight(4)
  >> landLeft(-1)
  >> landRight(-2)
say("return (0,0) >>= landLeft 1 >>= landRight 4 >>= landLeft (-1) >>= landRight (-2)", fail)

print("\n=== banana 强制失败 ===")
-- return (0,0) >>= landLeft 1 >>= banana >>= landRight 1
local slip = Maybe.Just({ 0, 0 })
  >> landLeft(1)
  >> banana
  >> landRight(1)
say("return (0,0) >>= landLeft 1 >>= banana >>= landRight 1", slip)

print("\n=== 用 ..（Haskell 的 >>）插入 Nothing ===")
-- return (0,0) >>= landLeft 1 >> Nothing >>= landRight 1
local peel = (Maybe.Just({ 0, 0 }) >> landLeft(1))
  .. Maybe.Nothing()
  >> landRight(1)
say("return (0,0) >>= landLeft 1 >> Nothing >>= landRight 1", peel)

print("\n=== 对照：成功 routine（两左、两右、再一左）===")
-- do { start <- return (0,0); first <- landLeft 2 start; ... }
local routine = Maybe.Just({ 0, 0 })
  >> landLeft(2)
  >> landRight(2)
  >> landLeft(1)
say("routine → Just (3,2)", routine)

-- 简单自检，失败则非零退出
local function expectJust(mp, left, right, msg)
  assert(Maybe.isJust(mp), msg .. ": expected Just")
  assert(mp.value[1] == left and mp.value[2] == right, msg .. ": wrong pole")
end

local function expectNothing(mp, msg)
  assert(Maybe.isNothing(mp), msg .. ": expected Nothing")
end

expectJust(ok, 2, 4, "success chain")
expectNothing(fail, "fail chain")
expectNothing(slip, "banana")
expectNothing(peel, ">> Nothing")
expectJust(routine, 3, 2, "routine")

print("\n全部断言通过。")
