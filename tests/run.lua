#!/usr/bin/env lua
-- tests/run.lua — 单子定律 + 符号糖 + Cont CPS 协程 + Identity/Reader/Writer/RWS + mdo 断言
--
-- 对每个 monad 检查三条定律（在样本上）：
--   左单位：  unit(a) >>= f      ≡  f(a)
--   右单位：  m >>= unit         ≡  m
--   结合律：  (m >>= f) >>= g    ≡  m >>= (λx. f(x) >>= g)
-- Cont / State 等「函数形」值经 run 抽成可比较的普通数据再 eq。
-- 失败则非零退出。在仓库根目录执行：lua tests/run.lua

package.path = "src/?.lua;" .. package.path

local Maybe = require("maybe")
local List = require("list")
local State = require("state")
local Status = require("status")
local Cont = require("cont")
local Coro = require("coro")
local Identity = require("identity")
local Reader = require("reader")
local Writer = require("writer")
local RWS = require("rws")

local failures = 0

-- 浅结构相等；忽略元表；函数形代理比 _fn 引用
local function eq(a, b)
  if type(a) ~= type(b) then return false end
  if type(a) ~= "table" then return a == b end
  -- Unwrap function-shaped proxies for structural compare of payloads if both are proxies
  if a._fn ~= nil and b._fn ~= nil then
    return a._fn == b._fn
  end
  -- shallow structural compare for tagged values / arrays (metatable ignored)
  local ka, kb = 0, 0
  for k in pairs(a) do ka = ka + 1 end
  for k in pairs(b) do kb = kb + 1 end
  if ka ~= kb then return false end
  for k, v in pairs(a) do
    if not eq(v, b[k]) then return false end
  end
  return true
end

local function assert_eq(actual, expected, msg)
  if not eq(actual, expected) then
    failures = failures + 1
    io.stderr:write("FAIL: " .. (msg or "?") .. "\n")
    return false
  end
  io.stdout:write("ok: " .. (msg or "?") .. "\n")
  return true
end

local function assert_true(cond, msg)
  if not cond then
    failures = failures + 1
    io.stderr:write("FAIL: " .. (msg or "?") .. "\n")
    return false
  end
  io.stdout:write("ok: " .. (msg or "?") .. "\n")
  return true
end

------------------------------------------------------------
-- 定律助手：run 把 monadic 值规范成可比较结果（默认恒等）
------------------------------------------------------------
local function test_laws(name, M, samples, f, g, run)
  run = run or function(x) return x end
  -- Left identity:  unit(a) >>= f  ==  f(a)
  for _, a in ipairs(samples) do
    local left = run(M.bind(M.unit(a), f))
    local right = run(f(a))
    assert_eq(left, right, name .. " left identity a=" .. tostring(a))
  end
  -- Right identity:  m >>= unit  ==  m
  for _, ma in ipairs({ M.unit(samples[1]), f(samples[1]) }) do
    local left = run(M.bind(ma, M.unit))
    local right = run(ma)
    assert_eq(left, right, name .. " right identity")
  end
  -- Associativity: (m >>= f) >>= g  ==  m >>= (\\x -> f(x) >>= g)
  local m0 = M.unit(samples[1])
  local left = run(M.bind(M.bind(m0, f), g))
  local right = run(M.bind(m0, function(x) return M.bind(f(x), g) end))
  assert_eq(left, right, name .. " associativity")
end

------------------------------------------------------------
-- Maybe：定律 + Nothing 短路 + >> / .. / 模块调用
------------------------------------------------------------
do
  local f = function(x) return Maybe.Just(x + 1) end
  local g = function(x) return Maybe.Just(x * 2) end
  test_laws("Maybe", Maybe, { 0, 1, 42 }, f, g)

  assert_eq(Maybe.bind(Maybe.Nothing(), f), Maybe.Nothing(), "Maybe Nothing short-circuit")
  assert_eq(Maybe.then_(Maybe.Just(3), function(x) return x * 10 end), Maybe.Just(30), "Maybe then_")

  -- Operator sugar: >> and ..
  local r1 = Maybe.Just(2) >> function(x) return Maybe.Just(x * 3) end
  assert_eq(r1, Maybe.Just(6), "Maybe >> bind")
  local r2 = Maybe.Nothing() >> f
  assert_eq(r2, Maybe.Nothing(), "Maybe >> Nothing short-circuit")
  local r3 = Maybe.Just(1) .. Maybe.Just(99)
  assert_eq(r3, Maybe.Just(99), "Maybe .. sequence discard left")
  local r4 = Maybe.Nothing() .. Maybe.Just(99)
  assert_eq(r4, Maybe.Nothing(), "Maybe .. Nothing short-circuit")
  assert_eq(Maybe(7), Maybe.Just(7), "Maybe(x) module call == unit")
end

------------------------------------------------------------
-- List：定律 + 展平 + 符号糖
------------------------------------------------------------
do
  local f = function(x) return { x, x + 1 } end
  local g = function(x) return { x * 10 } end
  test_laws("List", List, { 1, 2 }, f, g)

  assert_eq(List.bind({ 1, 2 }, function(x) return { x, x * 2 } end),
            { 1, 2, 2, 4 }, "List bind flatten")
  assert_eq(List.bind({}, f), {}, "List empty bind")

  local xs = List.wrap({ 1, 2 }) >> function(x) return List.wrap({ x, x * 10 }) end
  assert_eq(xs, { 1, 10, 2, 20 }, "List >> bind flatten")
  local seq = List.unit(1) .. List.wrap({ 7, 8 })
  assert_eq(seq, { 7, 8 }, "List .. sequence discard left")
  assert_eq(List(3), { 3 }, "List(x) module call == unit")
end

------------------------------------------------------------
-- State：定律（run 成 {a,s}）+ get/put/modify + 符号糖
------------------------------------------------------------
do
  local f = function(x)
    return State.bind(State.modify(function(s) return s + 1 end), function()
      return State.unit(x + 1)
    end)
  end
  local g = function(x)
    return State.bind(State.get(), function(s)
      return State.unit(x + s)
    end)
  end
  local run = function(ma)
    local a, s = State.runState(ma, 0)
    return { a = a, s = s }
  end
  test_laws("State", State, { 5, 10 }, f, g, run)

  local prog = State.bind(State.get(), function(s)
    return State.bind(State.put(s + 10), function()
      return State.bind(State.modify(function(x) return x * 2 end), function()
        return State.get()
      end)
    end)
  end)
  local a, s = State.runState(prog, 3)
  assert_eq(a, 26, "State get/put/modify value")
  assert_eq(s, 26, "State get/put/modify state")

  local sugar = State.unit(1) >> function(x)
    return State.put(x + 40) .. State.get()
  end
  local a2, s2 = State.runState(sugar, 0)
  assert_eq(a2, 41, "State >> / .. value")
  assert_eq(s2, 41, "State >> / .. state")
end

------------------------------------------------------------
-- Status：定律 + Err 短路 + 符号糖
------------------------------------------------------------
do
  local f = function(x) return Status.Ok(x + 1) end
  local g = function(x) return Status.Ok(tostring(x)) end
  test_laws("Status", Status, { 1, 2 }, f, g)

  assert_eq(Status.bind(Status.Err("boom"), f), Status.Err("boom"), "Status Err short-circuit")
  assert_eq(Status.bind(Status.Ok(7), function(x) return Status.Err("nope") end),
            Status.Err("nope"), "Status Ok then Err")

  assert_eq(Status.Ok(2) >> f, Status.Ok(3), "Status >> bind")
  assert_eq(Status.Ok(1) .. Status.Ok(5), Status.Ok(5), "Status .. sequence")
  assert_eq(Status.Err("x") .. Status.Ok(5), Status.Err("x"), "Status .. Err short-circuit")
end

------------------------------------------------------------
-- Cont：定律（runCont 恒等续延）+ runCont / 符号糖
------------------------------------------------------------
do
  local f = function(x) return Cont.unit(x + 1) end
  local g = function(x) return Cont.unit(x * 3) end
  local run = function(ma)
    return Cont.runCont(ma, function(x) return x end)
  end
  test_laws("Cont", Cont, { 1, 4 }, f, g, run)

  local r = Cont.runCont(
    Cont.bind(Cont.unit(2), function(x)
      return Cont.unit(x + 3)
    end),
    function(x) return x * 10 end
  )
  assert_eq(r, 50, "Cont runCont")

  local r2 = Cont.runCont(
    Cont.unit(2) >> function(x) return Cont.unit(x + 3) end,
    function(x) return x * 10 end
  )
  assert_eq(r2, 50, "Cont >> bind")

  local r3 = Cont.runCont(
    Cont.unit(1) .. Cont.unit(42),
    function(x) return x end
  )
  assert_eq(r3, 42, "Cont .. sequence discard left")
  assert_eq(Cont.runCont(Cont(9), function(x) return x end), 9, "Cont(x) module call")
end

------------------------------------------------------------
-- Coro：单次/两次 yield、无 yield、以及 >> 混用
------------------------------------------------------------
do
  -- Simple: yield once then return
  local body = Cont.bind(Coro.yield(10), function(resume_val)
    return Cont.unit(resume_val + 100)
  end)

  local a1 = Coro.start(body)
  assert_true(Coro.isYielded(a1), "coro first step Yielded")
  assert_eq(a1.value, 10, "coro yield value")

  local a2 = Coro.resume(a1, 5)
  assert_true(Coro.isDone(a2), "coro second step Done")
  assert_eq(a2.value, 105, "coro final value")

  -- Two yields
  local body2 = Cont.bind(Coro.yield("a"), function(v1)
    return Cont.bind(Coro.yield("b:" .. tostring(v1)), function(v2)
      return Cont.unit("done:" .. tostring(v2))
    end)
  end)
  local s0 = Coro.start(body2)
  assert_true(Coro.isYielded(s0) and s0.value == "a", "coro2 yield a")
  local s1 = Coro.resume(s0, 1)
  assert_true(Coro.isYielded(s1) and s1.value == "b:1", "coro2 yield b")
  local s2 = Coro.resume(s1, 2)
  assert_true(Coro.isDone(s2) and s2.value == "done:2", "coro2 done")

  -- No yield: immediate Done
  local immediate = Coro.start(Cont.unit(99))
  assert_true(Coro.isDone(immediate) and immediate.value == 99, "coro no-yield Done")

  -- Coro with operator sugar
  local body3 = Coro.yield(1) >> function(v)
    return Cont.unit(v + 10)
  end
  local c1 = Coro.start(body3)
  assert_true(Coro.isYielded(c1) and c1.value == 1, "coro sugar yield")
  local c2 = Coro.resume(c1, 7)
  assert_true(Coro.isDone(c2) and c2.value == 17, "coro sugar done")
end

------------------------------------------------------------
-- Cont：evalCont / mapCont / withCont / callCC 提前退出 / shift+reset
------------------------------------------------------------
do
  assert_eq(Cont.evalCont(Cont.unit(7)), 7, "Cont evalCont")

  -- mapCont：改造答案 r（在恒等续延下对结果 +1）
  local mapped = Cont.mapCont(function(r) return r + 1 end, Cont.unit(10))
  assert_eq(Cont.evalCont(mapped), 11, "Cont mapCont")

  -- withCont：变换续延本身；f(k) 先对输入加倍再交给原 k
  local with = Cont.withCont(function(k)
    return function(a)
      return k(a * 2)
    end
  end, Cont.unit(5))
  assert_eq(Cont.evalCont(with), 10, "Cont withCont")

  -- callCC 提前退出：escape(42) 后的 unit(999) 不会影响结果
  local early = Cont.callCC(function(escape)
    return Cont.unit(1) >> function(_)
      return escape(42) >> function(_)
        return Cont.unit(999)
      end
    end
  end)
  assert_eq(Cont.evalCont(early), 42, "Cont callCC early exit")

  -- 定界续延：reset(shift(λk. unit(eval(k3)+eval(k4))) >>= λx. unit(x*2)) == 14
  local delimited = Cont.bind(
    Cont.shift(function(k)
      return Cont.unit(Cont.evalCont(k(3)) + Cont.evalCont(k(4)))
    end),
    function(x)
      return Cont.unit(x * 2)
    end
  )
  assert_eq(Cont.reset(delimited), 14, "Cont shift/reset delimited")
end

------------------------------------------------------------
-- Coro：step / run / collect
------------------------------------------------------------
do
  local body = Cont.bind(Coro.yield(10), function(resume_val)
    return Cont.unit(resume_val + 100)
  end)

  -- step：Yielded → resume；Done → 原样
  local a1 = Coro.start(body)
  assert_true(Coro.isYielded(a1), "coro step start Yielded")
  local a2 = Coro.step(a1, 5)
  assert_true(Coro.isDone(a2) and a2.value == 105, "coro step resume Done")
  local a3 = Coro.step(a2, 999)
  assert_true(Coro.isDone(a3) and a3.value == 105, "coro step Done passthrough")

  -- run：handler 提供 resume 输入
  local final = Coro.run(body, function(yv)
    assert_eq(yv, 10, "coro run yield payload")
    return 5
  end)
  assert_eq(final, 105, "coro run final")

  -- collect：记录 yields，resume 用 true
  local gen = Cont.bind(Coro.yield(1), function(_)
    return Cont.bind(Coro.yield(2), function(_)
      return Cont.bind(Coro.yield(3), function(_)
        return Cont.unit("ok")
      end)
    end)
  end)
  local yields, fin = Coro.collect(gen)
  assert_eq(yields, { 1, 2, 3 }, "coro collect yields")
  assert_eq(fin, "ok", "coro collect final")
end


------------------------------------------------------------
-- Identity：定律 + runIdentity + 符号糖
------------------------------------------------------------
do
  local f = function(x) return Identity.unit(x + 1) end
  local g = function(x) return Identity.unit(x * 2) end
  local run = function(ma) return Identity.runIdentity(ma) end
  test_laws("Identity", Identity, { 0, 1, 7 }, f, g, run)

  assert_eq(Identity.runIdentity(Identity.unit(3) >> f), 4, "Identity >> bind")
  assert_eq(Identity.runIdentity(Identity.unit(1) .. Identity.unit(99)), 99, "Identity .. sequence")
  assert_eq(Identity.runIdentity(Identity(5)), 5, "Identity(x) module call")
end

------------------------------------------------------------
-- Reader：定律（固定 env）+ ask / asks / localEnv + 符号糖
------------------------------------------------------------
do
  local env0 = { n = 10, name = "alice" }
  local f = function(x)
    return Reader.ask() >> function(e)
      return Reader.unit(x + e.n)
    end
  end
  local g = function(x)
    return Reader.asks(function(e) return e.n end) >> function(n)
      return Reader.unit(x * n)
    end
  end
  local run = function(ma)
    return Reader.runReader(ma, env0)
  end
  test_laws("Reader", Reader, { 1, 2 }, f, g, run)

  assert_eq(Reader.runReader(Reader.ask(), env0), env0, "Reader ask")
  assert_eq(Reader.runReader(Reader.asks(function(e) return e.name end), env0),
            "alice", "Reader asks")

  local localized = Reader.localEnv(function(e)
    return { n = e.n * 2, name = e.name }
  end, Reader.asks(function(e) return e.n end))
  assert_eq(Reader.runReader(localized, env0), 20, "Reader localEnv")

  local sugar = Reader.unit(3) >> function(x)
    return Reader.ask() >> function(e)
      return Reader.unit(x + e.n)
    end
  end
  assert_eq(Reader.runReader(sugar, env0), 13, "Reader >> sugar")
  assert_eq(Reader.runReader(Reader.unit(1) .. Reader.unit(42), env0), 42, "Reader .. sequence")
end

------------------------------------------------------------
-- Writer：定律（比较 value+log）+ tell / listen / pass + WriterList
------------------------------------------------------------
do
  local f = function(x)
    return Writer.tell("f;") .. Writer.unit(x + 1)
  end
  local g = function(x)
    return Writer.tell("g;") .. Writer.unit(x * 2)
  end
  local run = function(ma)
    local v, w = Writer.runWriter(ma)
    return { value = v, log = w }
  end
  test_laws("Writer", Writer, { 1, 3 }, f, g, run)

  local prog = Writer.tell("a") .. Writer.tell("b") .. Writer.unit(7)
  local v, w = Writer.runWriter(prog)
  assert_eq(v, 7, "Writer tell chain value")
  assert_eq(w, "ab", "Writer tell chain log")

  local listened = Writer.listen(Writer.tell("xy") .. Writer.unit(1))
  local lv, lw = Writer.runWriter(listened)
  assert_eq(lv.value, 1, "Writer listen inner value")
  assert_eq(lv.log, "xy", "Writer listen inner log")
  assert_eq(lw, "xy", "Writer listen outer log")

  local passed = Writer.pass(Writer.tell("hello") .. Writer.unit({ 9, function(log)
    return log .. "!"
  end }))
  local pv, pw = Writer.runWriter(passed)
  assert_eq(pv, 9, "Writer pass value")
  assert_eq(pw, "hello!", "Writer pass transformed log")

  local WL = Writer.WriterList
  local lp = WL.tell({ "x" }) .. WL.tell({ "y", "z" }) .. WL.unit(true)
  local lv2, ll = WL.runWriter(lp)
  assert_eq(lv2, true, "WriterList value")
  assert_eq(ll, { "x", "y", "z" }, "WriterList log concat")
end

------------------------------------------------------------
-- RWS：定律 + ask/get/tell 组合
------------------------------------------------------------
do
  local env0 = { mul = 2 }
  local f = function(x)
    return RWS.tell("f;") .. RWS.modify(function(s) return s + 1 end) .. RWS.unit(x + 1)
  end
  local g = function(x)
    return RWS.ask() >> function(e)
      return RWS.get() >> function(s)
        return RWS.tell("g;") .. RWS.unit(x * e.mul + s)
      end
    end
  end
  local run = function(ma)
    local a, s, w = RWS.runRWS(ma, env0, 0)
    return { a = a, s = s, w = w }
  end
  test_laws("RWS", RWS, { 1, 4 }, f, g, run)

  local prog = RWS.ask() >> function(e)
    return RWS.get() >> function(s)
      return RWS.tell("go;") .. RWS.put(s + e.mul) .. RWS.unit(s)
    end
  end
  local a, s, w = RWS.runRWS(prog, env0, 5)
  assert_eq(a, 5, "RWS ask/get/tell value")
  assert_eq(s, 7, "RWS put state")
  assert_eq(w, "go;", "RWS tell log")
end


------------------------------------------------------------
-- mdo：expand / preprocess + 示例执行（foo、walk routine）
------------------------------------------------------------
do
  local mdo = require("mdo")

  -- expand：绑定嵌套
  local body = [[
  x <- Maybe.Just(3)
  y <- Maybe.Just("!")
  Maybe.Just(tostring(x) .. y)
]]
  local exp = mdo.expand(body, "Maybe")
  assert_true(exp:find(">> function%(x%)", 1, false) ~= nil, "mdo expand has >> function(x)")
  assert_true(exp:find(">> function%(y%)", 1, false) ~= nil, "mdo expand has >> function(y)")

  -- expand：中间裸表达式 → ..
  local body2 = [[
  Maybe.Just(1)
  x <- Maybe.Just(2)
  Maybe.Just(x)
]]
  local exp2 = mdo.expand(body2, "Maybe")
  assert_true(exp2:find("%.%.", 1, false) ~= nil, "mdo expand bare middle uses ..")

  -- expand：let
  local body3 = [[
  x <- Maybe.Just(10)
  let y = x + 1
  Maybe.Just(y)
]]
  local exp3 = mdo.expand(body3, "Maybe")
  local fn, err = load("local Maybe = require('maybe'); return " .. exp3, "mdo-let")
  assert_true(fn ~= nil, "mdo let expand loadable" .. (fn and "" or (": " .. tostring(err))))
  local rlet = fn()
  assert_eq(rlet, Maybe.Just(11), "mdo let result Just(11)")

  -- 非法：空块
  local ok_empty, err_empty = pcall(mdo.expand, "\n-- only comment\n", "Maybe")
  assert_true(not ok_empty, "mdo empty block errors")

  -- 非法：末行绑定
  local ok_tail, err_tail = pcall(mdo.expand, "x <- Maybe.Just(1)\n", "Maybe")
  assert_true(not ok_tail, "mdo trailing bind errors")

  -- preprocess + 执行 do_maybe_foo / walk（load 需去掉 shebang）
  local function readfile(path)
    local f = assert(io.open(path, "r"))
    local s = f:read("*a")
    f:close()
    return s
  end
  local function strip_shebang(s)
    if s:sub(1, 2) == "#!" then
      local nl = s:find("\n", 1, true)
      if nl then return s:sub(nl + 1) end
    end
    return s
  end
  local foo_src = strip_shebang(mdo.preprocess(readfile("examples/do_maybe_foo.mdo")))
  local foo_fn, foo_err = load(foo_src, "do_maybe_foo")
  assert_true(foo_fn ~= nil, "preprocess foo loadable" .. (foo_fn and "" or (": " .. tostring(foo_err))))
  if foo_fn then foo_fn() end

  local walk_src = strip_shebang(mdo.preprocess(readfile("examples/do_walk_the_line.mdo")))
  local walk_fn, walk_err = load(walk_src, "do_walk_the_line")
  assert_true(walk_fn ~= nil, "preprocess walk loadable" .. (walk_fn and "" or (": " .. tostring(walk_err))))
  if walk_fn then walk_fn() end

  -- 直接求值 foo 表达式
  local foo_only = mdo.expand([[
  x <- Maybe.Just(3)
  y <- Maybe.Just("!")
  Maybe.Just(tostring(x) .. y)
]], "Maybe")
  local foo2 = assert(load("local Maybe=require('maybe'); return " .. foo_only))()
  assert_eq(foo2, Maybe.Just("3!"), "mdo foo => Just \"3!\"")

  -- walk routine 表达式
  local walk_body = [[
  start <- Maybe.Just({ 0, 0 })
  first <- landLeft(2)(start)
  second <- landRight(2)(first)
  landLeft(1)(second)
]]
  local walk_exp = mdo.expand(walk_body, "Maybe")
  local walk_chunk = [[
local Maybe = require("maybe")
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
return ]] .. walk_exp
  local wr = assert(load(walk_chunk, "walk-routine"))()
  assert_true(Maybe.isJust(wr) and wr.value[1] == 3 and wr.value[2] == 2,
              "mdo walk routine Just (3,2)")

  ------------------------------------------------------------
  -- compile / loadfile / dofile / install_loader
  ------------------------------------------------------------
  mdo.install_loader()
  mdo.install_loader() -- idempotent

  local chunk = assert(mdo.loadfile("examples/do_maybe_foo.mdo"))
  assert_true(type(chunk) == "function", "mdo.loadfile returns function")
  chunk() -- runs example (prints / asserts)

  -- dofile 示例 .mdo
  mdo.dofile("examples/do_walk_the_line.mdo")

  -- 小临时文件：@mdo + 返回值，验证 dofile 传参与返回
  local tmp = os.tmpname() .. ".mdo"
  local tf = assert(io.open(tmp, "w"))
  tf:write([[
local Maybe = require("maybe")
local a = ...
local r = @mdo Maybe
  x <- Maybe.Just(a or 0)
  Maybe.Just(x + 1)
@end
return r
]])
  tf:close()
  local got = mdo.dofile(tmp, 41)
  assert_eq(got, Maybe.Just(42), "mdo.dofile temp @mdo Just(42)")
  os.remove(tmp)

  -- compile 直接从字符串
  local cfn, cerr = mdo.compile([[
local Maybe = require("maybe")
return @mdo Maybe
  Maybe.Just(9)
@end
]], "mdo-compile-test")
  assert_true(cfn ~= nil, "mdo.compile ok" .. (cfn and "" or (": " .. tostring(cerr))))
  assert_eq(cfn(), Maybe.Just(9), "mdo.compile result Just(9)")
end

------------------------------------------------------------
io.stdout:write("\n")
if failures > 0 then
  io.stderr:write(failures .. " failure(s)\n")
  os.exit(1)
else
  io.stdout:write("All tests passed.\n")
  os.exit(0)
end
