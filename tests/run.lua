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

  -- Cont.chain / map 热路径（与 .. / fmap 同语义）
  assert_eq(Cont.evalCont(Cont.chain(Cont.unit(1), Cont.unit(99))), 99, "Cont.chain")
  assert_eq(Cont.evalCont(Cont.map(Cont.unit(3), function(x) return x * 4 end)), 12, "Cont.map")
  assert_eq(Cont.evalCont(Cont.then_(Cont.unit(5), function(x) return x + 1 end)), 6, "Cont.then_")
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
-- Cont.withEnv：默认收集函数步骤、定义序 >>、同名替换、空环境
------------------------------------------------------------
do
  local cont_env = require("cont_env")
  assert_true(Cont.withEnv == cont_env.withEnv or type(Cont.withEnv) == "function",
              "Cont.withEnv available")

  local pipe = Cont.withEnv(function(_ENV)
    function add1(x)
      return Cont.unit(x + 1)
    end
    function times2(x)
      return Cont.unit(x * 2)
    end
  end)
  assert_eq(Cont.evalCont(pipe(3)), 8, "withEnv (3+1)*2 == 8")

  -- 非函数字段不进管道
  local pipe_skip = Cont.withEnv(function(_ENV)
    factor = 10
    function scale(x)
      return Cont.unit(x * factor)
    end
    function add1(x)
      return Cont.unit(x + 1)
    end
  end)
  -- scale 先于 add1；factor 非函数
  assert_eq(Cont.evalCont(pipe_skip(2)), 21, "withEnv non-fn field skipped (2*10)+1")

  -- 同名再赋：原地替换，保留首次次序
  local pipe_re = Cont.withEnv(function(_ENV)
    function a(x) return Cont.unit(x + 1) end
    function b(x) return Cont.unit(x * 2) end
    function a(x) return Cont.unit(x + 100) end
  end)
  assert_eq(Cont.evalCont(pipe_re(1)), 202, "withEnv redefine keeps order (1+100)*2")

  -- 空环境 ≡ unit
  local empty = Cont.withEnv(function(_ENV) end)
  assert_eq(Cont.evalCont(empty(7)), 7, "withEnv empty == unit")

  -- env.pipe / env.compose 在 body 返回后挂上，与返回值同引用
  local seen
  local pipe3 = Cont.withEnv(function(_ENV)
    function add1(x) return Cont.unit(x + 1) end
    seen = _ENV
  end)
  assert_eq(Cont.evalCont(pipe3(1)), 2, "withEnv single step")
  assert_true(seen.pipe == pipe3 and seen.compose == pipe3, "withEnv env.pipe/compose same")

  -- 确认 cont_env.withEnv 与 Cont.withEnv 一致（触发延迟加载）
  local p2 = cont_env.withEnv(function(_ENV)
    function times3(x) return Cont.unit(x * 3) end
  end)
  assert_eq(Cont.evalCont(p2(4)), 12, "cont_env.withEnv times3")
end

------------------------------------------------------------
-- Cont.withEnv 普通 a→b 自动提升（lift_step）
------------------------------------------------------------
do
  local cont_env = require("cont_env")
  local fx = require("fx")

  assert_true(Cont.is(Cont.unit(1)), "Cont.is Cont.unit")
  assert_true(not Cont.is(1), "Cont.is number false")
  assert_true(Cont.isCont == Cont.is, "Cont.isCont alias")

  -- 纯普通步进
  local plain = Cont.withEnv(function(_ENV)
    function add1(x) return x + 1 end
    function times2(x) return x * 2 end
  end)
  assert_eq(Cont.evalCont(plain(3)), 8, "plain steps (3+1)*2")

  -- Cont 步进仍可用
  local cont_only = Cont.withEnv(function(_ENV)
    function add1(x) return Cont.unit(x + 1) end
    function times2(x) return Cont.unit(x * 2) end
  end)
  assert_eq(Cont.evalCont(cont_only(3)), 8, "Cont steps still work")

  -- 混写：plain + Cont.unit + fx.wait
  local mixed = Cont.withEnv(function(_ENV)
    function bump(x) return x + 10 end
    function pause(x)
      return fx.wait(0.01) >> function(_)
        return Cont.unit(x)
      end
    end
    function tag(x) return Cont.unit({ n = x }) end
  end)
  local r = fx.run(mixed(5))
  assert_true(r.ok and r.value.n == 15, "mixed plain+fx.wait+Cont")

  -- 属性作用在 plain 步进上（lift 在属性前）
  local traced = Cont.withEnv(function(_ENV)
    __Trace__("plain")
    function add3(x) return x + 3 end
  end)
  assert_eq(Cont.evalCont(traced(1)), 4, "attr Trace on plain step")

  local before_plain = Cont.withEnv(function(_ENV)
    __Before__(function(x) return Cont.unit(x + 1) end)
    function times10(x) return x * 10 end
  end)
  assert_eq(Cont.evalCont(before_plain(2)), 30, "attr Before on plain step")

  -- init / finally 普通返回值
  local life = Cont.withEnv(function(_ENV)
    function init(x) return x + 1 end
    function step(x) return x * 2 end
    function finally(_outcome) return true end
  end)
  assert_eq(Cont.evalCont(life(3)), 8, "plain init/step/finally")
end

------------------------------------------------------------
-- Cont.withEnv 属性：Helper / Until / Before+After / 多属性 / 错误路径
------------------------------------------------------------
do
  local cont_env = require("cont_env")

  -- Helper：不进管道，但仍可调用
  local seen_env
  local pipe_h = Cont.withEnv(function(_ENV)
    __Helper__()
    function bump(x)
      return Cont.unit(x + 100)
    end
    function main(x)
      return bump(x) >> function(y)
        return Cont.unit(y * 2)
      end
    end
    seen_env = _ENV
  end)
  assert_eq(Cont.evalCont(pipe_h(3)), 206, "attr Helper: only main in pipe")
  assert_true(type(seen_env.bump) == "function", "attr Helper: bump stored on env")
  -- 管道只有 main：输入直接进 main；若 bump 也在管道会先 +100
  -- 用「空调用管道」对照：再测 NotStep 别名 + 两步
  local pipe_ns = Cont.withEnv(function(_ENV)
    __NotStep__()
    function hidden(x) return Cont.unit(x + 1) end
    function a(x) return Cont.unit(x + 1) end
    function b(x) return Cont.unit(x * 10) end
  end)
  assert_eq(Cont.evalCont(pipe_ns(2)), 30, "attr NotStep: (2+1)*10")

  -- Until：grow until >= 10
  local grow = Cont.withEnv(function(_ENV)
    __Until__(function(a) return a >= 10 end)
    function grow3(x) return Cont.unit(x + 3) end
  end)
  assert_eq(Cont.evalCont(grow(1)), 10, "attr Until: 1+3+3+3 == 10")

  -- Until already satisfied after first step
  local once = Cont.withEnv(function(_ENV)
    __Until__(function(a) return a >= 0 end)
    function id(x) return Cont.unit(x) end
  end)
  assert_eq(Cont.evalCont(once(5)), 5, "attr Until: pred true after first")

  -- Before / After order（参数名用 env，避免 _ENV 遮蔽 tostring）
  local log = {}
  local pipe_ba = Cont.withEnv(function(env)
    env.__Before__(function(x)
      log[#log + 1] = "B" .. tostring(x)
      return Cont.unit(x)
    end)
    env.__After__(function(x)
      log[#log + 1] = "A" .. tostring(x)
      return Cont.unit(x)
    end)
    env.add = function(x)
      log[#log + 1] = "S" .. tostring(x)
      return Cont.unit(x + 1)
    end
  end)
  assert_eq(Cont.evalCont(pipe_ba(7)), 8, "attr Before/After result")
  assert_eq(log[1], "B7", "attr Before first")
  assert_eq(log[2], "S7", "attr step middle")
  assert_eq(log[3], "A8", "attr After last")

  -- Multiple attrs: Wrap then Before
  local pipe_m = Cont.withEnv(function(_ENV)
    __Wrap__(function(step)
      return function(x)
        return step(x) >> function(y) return Cont.unit(y + 100) end
      end
    end)
    __Before__(function(x)
      return Cont.unit(x * 2)
    end)
    function core(x)
      return Cont.unit(x + 1)
    end
  end)
  -- Before first on raw: pre=*2 then core +1 → 2*x+1；再 Wrap 外层 +100
  -- Queue: Wrap then Before → apply Wrap first on core, then Before on that:
  --   w1 = Wrap(core) = λx. core(x)>> (+100)
  --   w2 = Before(w1) = λx. (*2)(x) >> w1
  -- 输入 3 → 6 → core 7 → 107
  assert_eq(Cont.evalCont(pipe_m(3)), 107, "attr multiple Wrap+Before")

  -- cont_env.attrs standalone Until
  local step = function(x) return Cont.unit(x + 2) end
  local looped = cont_env.attrs.__Until__(function(a) return a >= 9 end)(step)
  assert_eq(Cont.evalCont(looped(1)), 9, "attrs.__Until__ standalone 1+2*4")

  -- pending attr + non-function → error
  local ok_err = false
  local er = pcall(function()
    Cont.withEnv(function(_ENV)
      __Helper__()
      x = 1
    end)
  end)
  assert_true(not er, "attr pending + non-fn errors")

  -- pending attr at end of body → error
  er = pcall(function()
    Cont.withEnv(function(_ENV)
      __Before__(function(x) return Cont.unit(x) end)
    end)
  end)
  assert_true(not er, "attr pending at end of body errors")

  -- Helper removes prior step from pipe
  local pipe_rm = Cont.withEnv(function(_ENV)
    function a(x) return Cont.unit(x + 1) end
    function b(x) return Cont.unit(x * 2) end
    __Helper__()
    function a(x) return Cont.unit(x + 100) end  -- 从管道移除，仅保留 b
  end)
  assert_eq(Cont.evalCont(pipe_rm(3)), 6, "attr Helper redefine removes from pipe")
end

------------------------------------------------------------
-- Cont.withEnv 属性：Timeout / Retry / Require / Trace
------------------------------------------------------------
do
  local cont_env = require("cont_env")
  local os = os

  -- Timeout：忙等后超时 → 默认 tag
  local slow = Cont.withEnv(function(_ENV)
    __Timeout__(0.001)
    function busy(x)
      local t0 = os.clock()
      while os.clock() - t0 < 0.02 do end
      return Cont.unit(x + 1)
    end
  end)
  local r = Cont.evalCont(slow(10))
  assert_eq(r.tag, "timeout", "attr Timeout tag")
  assert_eq(r.value, 11, "attr Timeout value after step")
  assert_true(type(r.elapsed) == "number" and r.elapsed > 0.001, "attr Timeout elapsed")

  -- Timeout：未超时原值通过
  local fast = Cont.withEnv(function(_ENV)
    __Timeout__(1.0)
    function add1(x) return Cont.unit(x + 1) end
  end)
  assert_eq(Cont.evalCont(fast(5)), 6, "attr Timeout under limit")

  -- Timeout 自定义 on_timeout
  local custom_t = Cont.withEnv(function(_ENV)
    __Timeout__(0.001, function(a, elapsed)
      return Cont.unit({ ok = false, a = a, e = elapsed })
    end)
    function busy(x)
      local t0 = os.clock()
      while os.clock() - t0 < 0.02 do end
      return Cont.unit(x)
    end
  end)
  local ct = Cont.evalCont(custom_t(7))
  assert_true(ct.ok == false and ct.a == 7 and ct.e > 0.001, "attr Timeout on_timeout")

  -- Retry：奇数重试，用原 x
  local attempts = 0
  local retry_ok = Cont.withEnv(function(_ENV)
    __Retry__(5, function(a) return a % 2 ~= 0 end)
    function unstable(x)
      attempts = attempts + 1
      return Cont.unit(x + attempts)
    end
  end)
  attempts = 0
  assert_eq(Cont.evalCont(retry_ok(0)), 2, "attr Retry succeeds on even")
  assert_eq(attempts, 2, "attr Retry attempt count")

  -- Retry：始终 pred，返回最后 a
  attempts = 0
  local retry_fail = Cont.withEnv(function(_ENV)
    __Retry__(3, function(a) return true end)
    function always(x)
      attempts = attempts + 1
      return Cont.unit(x + attempts)
    end
  end)
  attempts = 0
  assert_eq(Cont.evalCont(retry_fail(10)), 13, "attr Retry last a after n")
  assert_eq(attempts, 3, "attr Retry n attempts")

  -- Require：拒绝（参数名用 env，避免 _ENV 遮蔽 type）
  local req = Cont.withEnv(function(env)
    env.__Require__(function(x) return type(x) == "number" and x > 0 end)
    env.double = function(x) return Cont.unit(x * 2) end
  end)
  assert_eq(Cont.evalCont(req(4)), 8, "attr Require pass")
  local rej = Cont.evalCont(req(-1))
  assert_eq(rej.tag, "rejected", "attr Require rejected tag")
  assert_eq(rej.value, -1, "attr Require rejected value")

  -- Require 自定义 on_fail
  local req2 = Cont.withEnv(function(env)
    env.__Require__(function(x) return x ~= nil end, function(_x)
      return Cont.unit("nil!")
    end)
    env.id = function(x) return Cont.unit(x) end
  end)
  assert_eq(Cont.evalCont(req2(nil)), "nil!", "attr Require on_fail")
  assert_eq(Cont.evalCont(req2("z")), "z", "attr Require on_fail pass")

  -- Trace：值不变（吞掉 print）
  local traced = Cont.withEnv(function(_ENV)
    __Trace__("t")
    function add1(x) return Cont.unit(x + 1) end
  end)
  assert_eq(Cont.evalCont(traced(3)), 4, "attr Trace preserves value")

  -- 独立 attrs
  local step = function(x) return Cont.unit(x + 1) end
  assert_eq(Cont.evalCont(cont_env.attrs.__Require__(function(x) return x > 0 end)(step)(2)), 3,
    "attrs.__Require__ standalone")
  assert_eq(Cont.evalCont(cont_env.attrs.__Retry__(2, function(a) return false end)(step)(1)), 2,
    "attrs.__Retry__ standalone no retry")
  assert_eq(Cont.evalCont(cont_env.attrs.__Trace__("x")(step)(1)), 2,
    "attrs.__Trace__ standalone")
  assert_eq(Cont.evalCont(cont_env.attrs.__Timeout__(1)(step)(1)), 2,
    "attrs.__Timeout__ standalone under limit")
end

------------------------------------------------------------
-- Cont.withEnv 属性：AfterStep / BeforeStep 管道顺序
------------------------------------------------------------
do
  local cont_env = require("cont_env")

  -- AfterStep：源码先写 later，排到 early 之后
  local pipe_as = Cont.withEnv(function(_ENV)
    __AfterStep__("early")
    function later(x) return Cont.unit(x * 10) end
    function early(x) return Cont.unit(x + 1) end
  end)
  assert_eq(Cont.evalCont(pipe_as(2)), 30, "attr AfterStep: (2+1)*10")

  -- BeforeStep：mid 插到 last 前
  local pipe_bs = Cont.withEnv(function(_ENV)
    function first(x) return Cont.unit(x + 1) end
    function last(x) return Cont.unit(x * 3) end
    __BeforeStep__("last")
    function mid(x) return Cont.unit(x + 10) end
  end)
  assert_eq(Cont.evalCont(pipe_bs(1)), 36, "attr BeforeStep: ((1+1)+10)*3")

  -- 无约束仍定义序
  local pipe_def = Cont.withEnv(function(_ENV)
    function a(x) return Cont.unit(x + 1) end
    function b(x) return Cont.unit(x * 2) end
  end)
  assert_eq(Cont.evalCont(pipe_def(3)), 8, "attr order default def order")

  -- 与 Helper 混用
  local pipe_h = Cont.withEnv(function(_ENV)
    __Helper__()
    function bump(x) return Cont.unit(x + 100) end
    __AfterStep__("a")
    function b(x)
      return bump(x) >> function(y) return Cont.unit(y * 2) end
    end
    function a(x) return Cont.unit(x + 1) end
  end)
  assert_eq(Cont.evalCont(pipe_h(3)), 208, "attr AfterStep + Helper")

  -- 同名重定义更新约束
  local pipe_re = Cont.withEnv(function(_ENV)
    __AfterStep__("a")
    function c(x) return Cont.unit(x + 1) end
    function a(x) return Cont.unit(x + 10) end
    function b(x) return Cont.unit(x * 2) end
    -- 重定义 c：去掉 AfterStep(a)，改为 BeforeStep(b) → a >> c >> b
    __BeforeStep__("b")
    function c(x) return Cont.unit(x + 1) end
  end)
  -- a= +10, c=+1, b=*2；输入 1 → 11 → 12 → 24
  assert_eq(Cont.evalCont(pipe_re(1)), 24, "attr redefine updates order constraints")

  -- 环：报错
  local ok_cycle = pcall(function()
    Cont.withEnv(function(_ENV)
      __AfterStep__("b")
      function a(x) return Cont.unit(x) end
      __AfterStep__("a")
      function b(x) return Cont.unit(x) end
    end)
  end)
  assert_true(not ok_cycle, "attr AfterStep cycle errors")

  -- 缺目标：报错
  local ok_miss = pcall(function()
    Cont.withEnv(function(_ENV)
      __AfterStep__("nope")
      function a(x) return Cont.unit(x) end
    end)
  end)
  assert_true(not ok_miss, "attr AfterStep missing target errors")

  local ok_miss2 = pcall(function()
    Cont.withEnv(function(_ENV)
      __BeforeStep__("ghost")
      function a(x) return Cont.unit(x) end
    end)
  end)
  assert_true(not ok_miss2, "attr BeforeStep missing target errors")

  -- AfterStep 指向 Helper → 缺目标
  local ok_h = pcall(function()
    Cont.withEnv(function(_ENV)
      __Helper__()
      function h(x) return Cont.unit(x) end
      __AfterStep__("h")
      function a(x) return Cont.unit(x) end
    end)
  end)
  assert_true(not ok_h, "attr AfterStep on Helper errors")

  -- 独立 attrs 描述符
  local d = cont_env.attrs.__AfterStep__("x")
  assert_true(type(d) == "table" and d.__attr_after_step == "x", "attrs.__AfterStep__ descriptor")
  local d2 = cont_env.attrs.__BeforeStep__("y")
  assert_true(type(d2) == "table" and d2.__attr_before_step == "y", "attrs.__BeforeStep__ descriptor")
end


------------------------------------------------------------
-- Cont.withEnv init / finally 生命周期
------------------------------------------------------------
do
  local cont_env = require("cont_env")
  local tostring = tostring

  -- 成功：init → step → finally；finally 不是步骤
  -- （_ENV 作参数时自由名查 env；勿在步内裸用 assert/type，除非 chunk 局部）
  local log = {}
  local pipe = Cont.withEnv(function(_ENV)
    function init(x)
      log[#log + 1] = "i"
      return Cont.unit(x + 1)
    end
    function step(x)
      log[#log + 1] = "s"
      return Cont.unit(x * 2)
    end
    function finally(outcome)
      log[#log + 1] = "f:" .. outcome.status
      if outcome.value ~= 8 then
        return Cont.throw("bad outcome value")
      end
      return Cont.unit(true)
    end
  end)
  assert_eq(Cont.evalCont(pipe(3)), 8, "init/finally success value")
  assert_eq(log[1], "i", "init first")
  assert_eq(log[2], "s", "step middle")
  assert_eq(log[3], "f:done", "finally on done")

  -- finally 单独存在不是步骤（恒等 + 清理）
  log = {}
  local only_f = Cont.withEnv(function(_ENV)
    function finally(outcome)
      log[#log + 1] = "f"
      return Cont.unit(true)
    end
  end)
  assert_eq(Cont.evalCont(only_f(9)), 9, "finally-only == unit")
  assert_eq(log[1], "f", "finally-only ran")

  -- Cont.throw：finally 先跑，再外层 catch
  log = {}
  local boom = Cont.withEnv(function(_ENV)
    function bad(_)
      return Cont.throw("x")
    end
    function finally(outcome)
      log[#log + 1] = "fail:" .. tostring(outcome.error)
      return Cont.unit(true)
    end
  end)
  local caught = Cont.evalCont(Cont.catch(boom(1), function(e)
    return Cont.unit("c:" .. e)
  end))
  assert_eq(caught, "c:x", "finally + Cont.catch value")
  assert_eq(log[1], "fail:x", "finally on Cont.throw")

  -- Coro.stop / Failed
  log = {}
  local stop_p = Cont.withEnv(function(_ENV)
    function a(_)
      return Coro.stop("r")
    end
    function b(_)
      log[#log + 1] = "no"
      return Cont.unit(1)
    end
    function finally(outcome)
      log[#log + 1] = "stop:" .. tostring(outcome.reason)
      return Cont.unit(true)
    end
  end)
  local st, payload = Coro.runEx(stop_p(0), function()
    return true
  end)
  assert_eq(st, "stopped", "finally Coro.stop status")
  assert_eq(payload, "r", "finally Coro.stop reason")
  assert_eq(log[1], "stop:r", "finally on Stopped")

  log = {}
  local fail_p = Cont.withEnv(function(_ENV)
    function a(_)
      return Coro.fail("e")
    end
    function finally(outcome)
      log[#log + 1] = "failed:" .. tostring(outcome.error)
      return Cont.unit(true)
    end
  end)
  st, payload = Coro.runEx(fail_p(0), function()
    return true
  end)
  assert_eq(st, "failed", "finally Coro.fail status")
  assert_eq(log[1], "failed:e", "finally on Failed")

  -- __Init__ / __Finally__ 标注
  log = {}
  local marked = Cont.withEnv(function(_ENV)
    __Init__()
    function open(x)
      log[#log + 1] = "open"
      return Cont.unit(x)
    end
    function work(x)
      log[#log + 1] = "work"
      return Cont.unit(x + 1)
    end
    __Finally__()
    function close(outcome)
      log[#log + 1] = "close:" .. outcome.status
      return Cont.unit(true)
    end
  end)
  assert_eq(Cont.evalCont(marked(1)), 2, "__Init__/__Finally__ value")
  assert_eq(log[1], "open", "__Init__ ran")
  assert_eq(log[2], "work", "step ran")
  assert_eq(log[3], "close:done", "__Finally__ ran")

  -- 固定名 finally 与 __Finally__ 并存：定义序
  log = {}
  local multi = Cont.withEnv(function(_ENV)
    function step(x)
      return Cont.unit(x)
    end
    function finally(outcome)
      log[#log + 1] = "a"
      return Cont.unit(true)
    end
    __Finally__()
    function other(outcome)
      log[#log + 1] = "b"
      return Cont.unit(true)
    end
  end)
  Cont.evalCont(multi(0))
  assert_eq(log[1], "a", "multi cleanup order 1")
  assert_eq(log[2], "b", "multi cleanup order 2")

  -- Cont.finally / init_finally 独立 API
  local n = 0
  local m = Cont.finally(Cont.unit(5), function(o)
    n = n + 1
    assert(o.status == "done" and o.value == 5)
    return Cont.unit(true)
  end)
  assert_eq(Cont.evalCont(m), 5, "Cont.finally value")
  assert_eq(n, 1, "Cont.finally ran")

  n = 0
  local m2 = Cont.init_finally(
    Cont.unit(3),
    function()
      n = n + 10
      return Cont.unit(true)
    end,
    function()
      n = n + 1
      return Cont.unit(true)
    end
  )
  assert_eq(Cont.evalCont(m2), 3, "Cont.init_finally value")
  assert_eq(n, 11, "Cont.init_finally init+finally")

  assert_true(cont_env.with_finally == Cont.finally or type(cont_env.with_finally) == "function",
    "cont_env.with_finally exported")
end


------------------------------------------------------------
-- Cont.throw / Cont.catch / Cont.protect
------------------------------------------------------------
do
  local v = Cont.evalCont(Cont.catch(
    Cont.unit(1) >> function(_)
      return Cont.throw("boom")
    end,
    function(err)
      return Cont.unit("caught:" .. tostring(err))
    end
  ))
  assert_eq(v, "caught:boom", "Cont.catch catches throw")

  local nested = Cont.evalCont(Cont.catch(
    Cont.catch(
      Cont.throw("in"),
      function(_) return Cont.throw("out") end
    ),
    function(e) return Cont.unit("outer:" .. tostring(e)) end
  ))
  assert_eq(nested, "outer:out", "Cont.catch nested rethrow")

  local ok, err = pcall(function()
    Cont.evalCont(Cont.throw("uncaught"))
  end)
  assert_true(not ok and tostring(err):find("uncaught Cont.throw", 1, true),
    "Cont.throw uncaught errors")

  local prot = Cont.evalCont(Cont.protect(Cont.wrap(function(_k)
    error("lua-boom", 0)
  end)))
  assert_true(type(prot) == "table" and prot.tag == "error", "Cont.protect → error table")
  assert_true(tostring(prot.error):find("lua-boom", 1, true), "Cont.protect error payload")
end

------------------------------------------------------------
-- Coro：stop / fail / runEx / step passthrough
------------------------------------------------------------
do
  local a = Coro.start(Coro.stop("r"))
  assert_true(Coro.isStopped(a) and a.reason == "r", "coro stop Answer")

  local b = Coro.start(Coro.fail("e"))
  assert_true(Coro.isFailed(b) and b.error == "e", "coro fail Answer")

  -- step 对 Stopped/Failed 原样返回
  assert_true(Coro.isStopped(Coro.step(a, 1)) and Coro.step(a, 1).reason == "r",
    "coro step Stopped passthrough")
  assert_true(Coro.isFailed(Coro.step(b, 1)), "coro step Failed passthrough")

  -- run：成功返回值；Stopped/Failed 返回 nil, answer
  local body = Coro.yield(1) >> function(_)
    return Coro.stop("mid")
  end
  local v, ans = Coro.run(body, function(_) return true end)
  assert_true(v == nil and Coro.isStopped(ans) and ans.reason == "mid",
    "coro run Stopped → nil, answer")

  local v2, ans2 = Coro.run(Coro.fail("f"), function() end)
  assert_true(v2 == nil and Coro.isFailed(ans2), "coro run Failed → nil, answer")

  local st, payload = Coro.runEx(Cont.unit(9), function() end)
  assert_eq(st, "done", "coro runEx done status")
  assert_eq(payload, 9, "coro runEx done payload")

  st, payload = Coro.runEx(Coro.stop("s"), function() end)
  assert_eq(st, "stopped", "coro runEx stopped")
  assert_eq(payload, "s", "coro runEx stopped reason")

  st, payload = Coro.runEx(Coro.fail(42), function() end)
  assert_eq(st, "failed", "coro runEx failed")
  assert_eq(payload, 42, "coro runEx failed error")

  -- mid-flow stop after yield
  local mid = Cont.bind(Coro.yield("y"), function(_)
    return Coro.fail("after-yield")
  end)
  local y1 = Coro.start(mid)
  assert_true(Coro.isYielded(y1), "coro fail after yield: first Yielded")
  local y2 = Coro.resume(y1, true)
  assert_true(Coro.isFailed(y2) and y2.error == "after-yield", "coro fail after yield")
end

------------------------------------------------------------
-- fx：wait / connect / click + 瞬时 handlers
------------------------------------------------------------
do
  local fx = require("fx")

  local events = {}
  local instant = {
    wait = function(req)
      events[#events + 1] = { kind = "wait", seconds = req.seconds }
      return true
    end,
    connect = function(req)
      events[#events + 1] = { kind = "connect", host = req.host }
      return { ok = true, host = req.host, latency = 0 }
    end,
    click = function(req)
      events[#events + 1] = { kind = "click", target = req.target }
      return { ok = true, target = req.target }
    end,
  }

  -- 单独 wait
  events = {}
  local wr = fx.run(fx.wait(0.05), instant)
  assert_true(wr.ok, "fx.wait ok")
  assert_eq(wr.value, true, "fx.wait resumes to true")
  assert_eq(#events, 1, "fx.wait one event")
  assert_eq(events[1].kind, "wait", "fx.wait event kind")
  assert_eq(events[1].seconds, 0.05, "fx.wait event seconds")

  -- connect
  events = {}
  local cr = fx.run(fx.connect("h.example"), instant)
  assert_true(cr.ok, "fx.connect result ok")
  local c = cr.value
  assert_true(c.ok and c.host == "h.example", "fx.connect mock ok")
  assert_eq(events[1].kind, "connect", "fx.connect event kind")

  -- click
  events = {}
  local kr = fx.run(fx.click("btn"), instant)
  assert_true(kr.ok, "fx.click result ok")
  local k = kr.value
  assert_true(k.ok and k.target == "btn", "fx.click mock ok")
  assert_eq(events[1].kind, "click", "fx.click event kind")

  -- 串联 + withEnv
  events = {}
  local pipe = Cont.withEnv(function(_ENV)
    function a(_)
      return fx.wait(0.01) >> function(_)
        return fx.click("go")
      end
    end
    function b(click_res)
      return fx.connect("api") >> function(conn)
        return Cont.unit({ click = click_res, conn = conn })
      end
    end
  end)
  local pr = fx.run(pipe(nil), instant)
  assert_true(pr.ok, "fx pipe ok")
  local final = pr.value
  assert_true(final.click.ok and final.click.target == "go", "fx pipe click")
  assert_true(final.conn.ok and final.conn.host == "api", "fx pipe connect")
  assert_eq(#events, 3, "fx pipe three events")
  assert_eq(events[1].kind, "wait", "fx pipe event1 wait")
  assert_eq(events[2].kind, "click", "fx pipe event2 click")
  assert_eq(events[3].kind, "connect", "fx pipe event3 connect")

  -- stop / fail / cancel
  local stop_r = fx.run(fx.wait(0.01) >> function(_) return fx.stop("bye") end, instant)
  assert_true(stop_r.stopped and stop_r.reason == "bye", "fx.stop → stopped")

  local fail_r = fx.run(fx.fail("e1"), instant)
  assert_true(fail_r.failed and fail_r.error == "e1", "fx.fail → failed")

  local token = { cancelled = false }
  local waits = 0
  local cancel_h = {
    wait = function(req)
      waits = waits + 1
      token.cancelled = true
      return true
    end,
  }
  local body = fx.wait(0.01) >> function(_)
    return fx.wait(0.01) >> function(_)
      return Cont.unit("done")
    end
  end
  local can_r = fx.run(body, cancel_h, { cancel = token })
  assert_true(can_r.stopped and can_r.reason == "cancelled", "fx cancel token")
  assert_eq(waits, 1, "fx cancel after first wait")

  local try_r = fx.try(fx.fail("x"), instant, {
    on_fail = function(err) return "recovered:" .. tostring(err) end,
  })
  assert_true(try_r.ok and try_r.value == "recovered:x", "fx.try on_fail")
end

------------------------------------------------------------
-- fx：when_all / when_any / run_parallel / cancel / Failed
------------------------------------------------------------
do
  local fx = require("fx")

  local instant = {
    wait = function(req) return true end,
    connect = function(req) return { ok = true, host = req.host } end,
    click = function(req) return { ok = true, target = req.target } end,
  }

  -- when_all 结果顺序
  local r_all = fx.run_all({
    Cont.unit("a"),
    Cont.unit("b"),
    Cont.unit("c"),
  }, instant)
  assert_true(r_all.ok, "run_all ok")
  assert_eq(r_all.values[1], "a", "when_all order[1]")
  assert_eq(r_all.values[2], "b", "when_all order[2]")
  assert_eq(r_all.values[3], "c", "when_all order[3]")

  -- Cont 组合子 when_all
  local r_wa = fx.run(fx.when_all({
    fx.connect("h1"),
    fx.click("btn"),
    Cont.unit(42),
  }), instant)
  assert_true(r_wa.ok, "fx.when_all via run ok")
  assert_eq(r_wa.value[1].host, "h1", "when_all connect")
  assert_eq(r_wa.value[2].target, "btn", "when_all click")
  assert_eq(r_wa.value[3], 42, "when_all unit")

  -- when_any 胜者
  local r_any = fx.run_any({
    fx.wait(0.05) >> function(_) return Cont.unit("slow") end,
    fx.wait(0.01) >> function(_) return Cont.unit("fast") end,
  }, nil) -- 真实时间轮
  assert_true(r_any.ok, "run_any ok")
  assert_eq(r_any.index, 2, "when_any winner index")
  assert_eq(r_any.value, "fast", "when_any winner value")

  local r_any_c = fx.run(fx.when_any({
    Cont.unit("only"),
  }), instant)
  assert_true(r_any_c.ok, "when_any Cont ok")
  assert_eq(r_any_c.value.index, 1, "when_any Cont index")
  assert_eq(r_any_c.value.value, "only", "when_any Cont value")

  -- cancel 在并行中
  local token = { cancelled = false }
  local nconn = 0
  local cancel_h = {
    connect = function(req)
      nconn = nconn + 1
      token.cancelled = true
      return { ok = true, host = req.host }
    end,
    wait = function(req) return true end,
  }
  -- 两路：一路 connect（会置 cancelled），一路长 wait；调度器在下一轮检查 cancel
  local r_can = fx.run_all({
    fx.connect("x") >> function(_)
      return fx.wait(0.05) >> function(_) return Cont.unit(1) end
    end,
    fx.wait(0.05) >> function(_) return Cont.unit(2) end,
  }, cancel_h, { cancel = token })
  assert_true(r_can.stopped and r_can.reason == "cancelled", "parallel cancel")
  assert_true(nconn >= 1, "parallel cancel saw connect")

  -- Failed 中止 when_all
  local r_fail = fx.run_all({
    Cont.unit(1),
    fx.fail("boom"),
    Cont.unit(3),
  }, instant)
  assert_true(r_fail.failed and r_fail.error == "boom", "when_all Failed aborts")
  assert_eq(r_fail.index, 2, "when_all Failed index")

  -- 并行 wait wall clock（宽松；用 fx_sched.now，勿用 os.clock）
  local sched = require("fx_sched")
  local t0 = sched.now()
  local r_par = fx.run_all({ fx.wait(0.04), fx.wait(0.04) }, nil)
  local elapsed = sched.now() - t0
  assert_true(r_par.ok, "parallel wait ok")
  assert_true(elapsed < 0.075, "parallel wait wall < 0.075 got " .. tostring(elapsed))
  assert_true(elapsed >= 0.035, "parallel wait wall >= 0.035 got " .. tostring(elapsed))
end

------------------------------------------------------------
-- fx：fork / join / join_handles
------------------------------------------------------------
do
  local fx = require("fx")
  local sched = require("fx_sched")

  local instant = {
    wait = function(req) return true end,
    connect = function(req) return { ok = true, host = req.host } end,
    click = function(req) return { ok = true, target = req.target } end,
  }

  -- fork + join 取值
  local r_fj = fx.run(
    fx.fork(Cont.unit(99)) >> function(h)
      return fx.join(h)
    end,
    instant
  )
  assert_true(r_fj.ok, "fork+join ok")
  assert_eq(r_fj.value, 99, "fork+join value")

  -- join_handles 顺序
  local r_ord = fx.run(
    fx.fork(Cont.unit("first")) >> function(h1)
      return fx.fork(Cont.unit("second")) >> function(h2)
        return fx.join_handles({ h1, h2 })
      end
    end,
    instant
  )
  assert_true(r_ord.ok, "join_handles ok")
  assert_eq(r_ord.value[1], "first", "join_handles order[1]")
  assert_eq(r_ord.value[2], "second", "join_handles order[2]")

  -- 并行 wall clock：fork 两路 wait 再 join
  local t0 = sched.now()
  local r_par = fx.run(
    fx.fork(fx.wait(0.04) >> function(_) return Cont.unit(1) end) >> function(h1)
      return fx.fork(fx.wait(0.04) >> function(_) return Cont.unit(2) end) >> function(h2)
        return fx.join_handles({ h1, h2 })
      end
    end,
    nil
  )
  local elapsed = sched.now() - t0
  assert_true(r_par.ok, "fork/join parallel wait ok")
  assert_eq(r_par.value[1], 1, "fork/join val1")
  assert_eq(r_par.value[2], 2, "fork/join val2")
  assert_true(elapsed < 0.075, "fork/join wall < 0.075 got " .. tostring(elapsed))
  assert_true(elapsed >= 0.035, "fork/join wall >= 0.035 got " .. tostring(elapsed))

  -- 子 Failed → join 失败
  local r_fail = fx.run(
    fx.fork(fx.fail("boom")) >> function(h)
      return fx.join(h)
    end,
    instant
  )
  assert_true(r_fail.failed and r_fail.error == "boom", "join Failed propagates")

  -- cancel 在 forked wait 期间
  local token = { cancelled = false }
  local nconn = 0
  local cancel_h = {
    connect = function(req)
      nconn = nconn + 1
      token.cancelled = true
      return { ok = true, host = req.host }
    end,
  }
  local r_can = fx.run(
    fx.fork(fx.wait(0.08) >> function(_) return Cont.unit("slow") end) >> function(h)
      return fx.connect("x") >> function(_)
        return fx.join(h)
      end
    end,
    cancel_h,
    { cancel = token }
  )
  assert_true(r_can.stopped and r_can.reason == "cancelled", "cancel during forked wait")
  assert_true(nconn >= 1, "cancel saw connect")
end


------------------------------------------------------------
-- fx：map_parallel 有限并发池
------------------------------------------------------------
do
  local fx = require("fx")
  local sched = require("fx_sched")

  -- 空列表
  local r0 = fx.run(fx.map_parallel({}, function(_x, _i) return Cont.unit(1) end))
  assert_true(r0.ok and #r0.value == 0, "map_parallel empty")

  -- 顺序
  local r_ord = fx.run(fx.map_parallel({ "a", "b", "c" }, function(item, i)
    return Cont.unit(item .. tostring(i))
  end, { concurrency = 2 }))
  assert_true(r_ord.ok, "map_parallel order ok")
  assert_eq(r_ord.value[1], "a1", "map_parallel [1]")
  assert_eq(r_ord.value[2], "b2", "map_parallel [2]")
  assert_eq(r_ord.value[3], "c3", "map_parallel [3]")

  -- 墙钟：6 × wait(0.03), concurrency=2 → ≈ 3 批 ≈ 0.09，串行 ≈ 0.18
  local t0 = sched.now()
  local r_wall = fx.run(fx.map_parallel({ 1, 2, 3, 4, 5, 6 }, function(x, _i)
    return fx.wait(0.03) >> function(_)
      return Cont.unit(x * 10)
    end
  end, { concurrency = 2 }))
  local elapsed = sched.now() - t0
  assert_true(r_wall.ok, "map_parallel wall ok")
  assert_eq(r_wall.value[1], 10, "map_parallel wall val1")
  assert_eq(r_wall.value[6], 60, "map_parallel wall val6")
  assert_true(elapsed < 0.15, "map_parallel wall < 0.15 got " .. tostring(elapsed))
  assert_true(elapsed >= 0.07, "map_parallel wall >= 0.07 got " .. tostring(elapsed))

  -- for_each_parallel
  local n = 0
  local r_fe = fx.run(fx.for_each_parallel({ 1, 2 }, function(_x, _i)
    n = n + 1
    return Cont.unit(false)
  end, { concurrency = 1 }))
  assert_true(r_fe.ok and r_fe.value == true and n == 2, "for_each_parallel")

  -- concurrency < 1 应报错
  local ok_c, err_c = pcall(function()
    fx.map_parallel({ 1 }, function(x) return Cont.unit(x) end, { concurrency = 0 })
  end)
  assert_true(not ok_c, "concurrency >= 1 enforced")
end


------------------------------------------------------------
-- fx：with_timeout 超时竞速
------------------------------------------------------------
do
  local fx = require("fx")
  local sched = require("fx_sched")

  -- 限时内成功
  local t0 = sched.now()
  local r_ok = fx.run(fx.with_timeout(
    fx.wait(0.02) >> function(_) return Cont.unit(7) end,
    0.10
  ))
  local e_ok = sched.now() - t0
  assert_true(r_ok.ok and r_ok.value == 7, "with_timeout success")
  assert_true(e_ok < 0.07, "with_timeout success wall < 0.07 got " .. tostring(e_ok))

  -- 超时 → Failed("timeout")
  local t1 = sched.now()
  local r_to = fx.run(fx.with_timeout(
    fx.wait(0.08) >> function(_) return Cont.unit("late") end,
    0.02
  ))
  local e_to = sched.now() - t1
  assert_true(r_to.failed and r_to.error == "timeout", "with_timeout Failed(timeout)")
  assert_true(e_to < 0.06, "with_timeout wall < 0.06 got " .. tostring(e_to))
  assert_true(e_to >= 0.015, "with_timeout wall >= 0.015 got " .. tostring(e_to))

  -- 自定义 on_timeout
  local r_custom = fx.run(fx.with_timeout(
    fx.wait(0.05),
    0.01,
    { on_timeout = "my-deadline" }
  ))
  assert_true(r_custom.failed and r_custom.error == "my-deadline", "on_timeout custom")

  -- body 先 Failed
  local r_fail = fx.run(fx.with_timeout(fx.fail("boom"), 1.0))
  assert_true(r_fail.failed and r_fail.error == "boom", "body Failed before timeout")
end


------------------------------------------------------------
-- fx：截止时间向下传播（fork 继承 deadline）
------------------------------------------------------------
do
  local fx = require("fx")
  local Cont = require("cont")
  local Scheduler = require("scheduler")
  local Sched = require("fx_sched")
  local GameSim = require("game_sim")

  -- VirtualClock：父 with_timeout 超时 → fork 子 Stopped，finally 跑
  local child_fin = false
  local child_done = false
  local clock = Scheduler.VirtualClock()
  local child_ma = Cont.finally(
    fx.wait(5.0) >> function(_)
      child_done = true
      return Cont.unit("late-child")
    end,
    function(outcome)
      child_fin = outcome.status == "stopped"
      return true
    end
  )
  local flow = Sched.start_session(
    fx.with_timeout(
      fx.fork(child_ma) >> function(h)
        return fx.join(h)
      end,
      0.3
    ),
    {},
    { scheduler = clock }
  )
  assert_true(not flow.done, "deadline inherit: pending")
  clock.advance(0.29)
  assert_true(not flow.done, "deadline inherit: before timeout")
  clock.advance(0.02)
  assert_true(flow.done and flow.result.failed and flow.result.error == "timeout",
    "deadline inherit: parent Failed(timeout)")
  assert_true(child_done == false, "deadline inherit: child not Done")
  assert_true(child_fin, "deadline inherit: child finally on Stopped")

  -- 子更紧 with_timeout：在父 deadline 之前 Failed
  clock = Scheduler.VirtualClock()
  flow = Sched.start_session(
    fx.with_timeout(
      fx.fork(
        fx.with_timeout(fx.wait(5.0), 0.1, { on_timeout = "child-to" })
      ) >> function(h)
        return fx.join(h)
      end,
      1.0
    ),
    {},
    { scheduler = clock }
  )
  clock.advance(0.1)
  assert_true(flow.done and flow.result.failed and flow.result.error == "child-to",
    "tighter child with_timeout wins")

  -- session opts.timeout：根 Failed，fork 子 Stopped + finally
  clock = Scheduler.VirtualClock()
  child_fin = false
  child_done = false
  child_ma = Cont.finally(
    fx.wait(2.0) >> function(_)
      child_done = true
      return Cont.unit(1)
    end,
    function(outcome)
      child_fin = outcome.status == "stopped"
      return true
    end
  )
  flow = Sched.start_session(
    fx.fork(child_ma) >> function(h)
      return fx.join(h)
    end,
    {},
    { scheduler = clock, timeout = 0.25 }
  )
  clock.advance(0.25)
  assert_true(flow.done and flow.result.failed and flow.result.error == "timeout",
    "opts.timeout session Failed")
  assert_true(child_done == false and child_fin, "opts.timeout child finally")

  -- GameSim：游戏时间 with_timeout 取消 fork 子树
  local sim = GameSim.new({ dt = 0.05 })
  child_fin = false
  child_done = false
  local r = sim:run(
    fx.with_timeout(
      fx.fork(
        Cont.finally(
          fx.wait(2.0) >> function(_)
            child_done = true
            return Cont.unit("x")
          end,
          function(outcome)
            child_fin = outcome.status == "stopped"
            return true
          end
        )
      ) >> function(h)
        return fx.join(h)
      end,
      0.2
    )
  )
  assert_true(r.failed and r.error == "timeout", "GameSim deadline Failed")
  assert_true(child_done == false and child_fin, "GameSim child finally")
  assert_true(sim:now() >= 0.2 - 1e-9 and sim:now() < 0.35, "GameSim time ~ timeout")
end


------------------------------------------------------------
-- fx：取消传播树 / join cancel_siblings
------------------------------------------------------------
do
  local fx = require("fx")
  local sched = require("fx_sched")

  -- session cancel 停止 fork 子任务
  local token = { cancelled = false }
  local child_done = false
  local r_can = fx.run(
    fx.fork(fx.wait(0.12) >> function(_)
      child_done = true
      return Cont.unit("slow")
    end) >> function(h)
      return fx.connect("x") >> function(_)
        return fx.join(h)
      end
    end,
    {
      connect = function(req)
        token.cancelled = true
        return { ok = true, host = req.host }
      end,
    },
    { cancel = token }
  )
  assert_true(r_can.stopped and r_can.reason == "cancelled", "cancel tree session")
  assert_true(child_done == false, "cancel tree child stopped")

  -- join cancel_siblings
  local b_done = false
  local t0 = sched.now()
  local r_sib = fx.run(
    fx.fork(fx.wait(0.025) >> function(_) return Cont.unit("fast") end) >> function(hA)
      return fx.fork(fx.wait(0.20) >> function(_)
        b_done = true
        return Cont.unit("slow")
      end) >> function(_hB)
        return fx.join(hA, { cancel_siblings = true })
      end
    end
  )
  local e = sched.now() - t0
  assert_true(r_sib.ok and r_sib.value == "fast", "cancel_siblings join value")
  assert_true(b_done == false, "cancel_siblings stopped sibling")
  assert_true(e < 0.10, "cancel_siblings wall < 0.10 got " .. tostring(e))

  -- join_handles cancel_siblings
  local c_done = false
  local r_jh = fx.run(
    fx.fork(Cont.unit(1)) >> function(h1)
      return fx.fork(Cont.unit(2)) >> function(h2)
        return fx.fork(fx.wait(0.15) >> function(_)
          c_done = true
          return Cont.unit(3)
        end) >> function(_h3)
          return fx.join_handles({ h1, h2 }, { cancel_siblings = true })
        end
      end
    end
  )
  assert_true(r_jh.ok and r_jh.value[1] == 1 and r_jh.value[2] == 2, "join_handles cancel_siblings vals")
  assert_true(c_done == false, "join_handles cancel_siblings stopped extra")
end

------------------------------------------------------------
-- GameSim / scheduler：游戏时间 wait、pause、cancel、wait_event、实体 finally
------------------------------------------------------------
do
  local fx = require("fx")
  local GameSim = require("game_sim")
  local Scheduler = require("scheduler")

  -- 无 scheduler：旧行为仍可用（忙等路径存在即可）
  local r0 = fx.run(fx.wait(0.001) >> function(_) return Cont.unit(42) end, {
    wait = function() return true end,
  })
  assert_true(r0.ok and r0.value == 42, "fx.run without scheduler still works")

  -- VirtualClock + start_session
  local clock = Scheduler.VirtualClock()
  local flow = require("fx_sched").start_session(
    fx.wait(0.5) >> function(_) return Cont.unit("v") end,
    {},
    { scheduler = clock }
  )
  assert_true(not flow.done, "virtual: not done before advance")
  clock.advance(0.4)
  assert_true(not flow.done, "virtual: still waiting")
  clock.advance(0.1)
  assert_true(flow.done and flow.result.ok and flow.result.value == "v", "virtual: done after advance")

  -- 游戏时间 wait
  local sim = GameSim.new({ dt = 0.1 })
  local r = sim:run(fx.wait(0.3) >> function(_) return Cont.unit(sim:now()) end)
  assert_true(r.ok and r.value >= 0.3 - 1e-9, "game wait value")
  assert_true(sim:now() >= 0.3 - 1e-9, "game wait now")

  -- pause 推迟
  sim = GameSim.new({ dt = 0.1 })
  flow = sim:start_flow(nil, fx.wait(0.4) >> function(_) return Cont.unit(true) end)
  sim:tick(0.2)
  sim:set_paused(true)
  local t_paused = sim:now()
  sim:tick(1.0)
  assert_true(sim:now() == t_paused, "pause freezes time")
  assert_true(not flow.done, "pause defers wait")
  sim:set_paused(false)
  sim:tick(0.2)
  assert_true(flow.done and flow.result.ok, "resume after pause")

  -- cancel 清 timer；迟到回调忽略
  sim = GameSim.new({ dt = 0.1 })
  local late = false
  local handle = sim.schedule(0.5, function() late = true end)
  sim.cancel(handle)
  sim:tick(1.0)
  assert_true(late == false, "cancelled timer ignored")

  sim = GameSim.new({ dt = 0.1 })
  local resumed = false
  flow = sim:start_flow(nil, fx.wait(1.0) >> function(_)
    resumed = true
    return Cont.unit(true)
  end)
  assert_true(not flow.done, "wait pending before cancel")
  flow.cancel("bye")
  assert_true(flow.done and flow.result.stopped, "flow cancelled")
  sim:tick(2.0)
  assert_true(resumed == false, "cancelled wait not resumed")

  -- wait_event
  sim = GameSim.new()
  flow = sim:start_flow(nil, fx.wait_event("go") >> function(p)
    return Cont.unit(p)
  end)
  assert_true(not flow.done, "wait_event pending")
  sim:emit("go", { n = 7 })
  assert_true(flow.done and flow.result.ok and flow.result.value.n == 7, "wait_event resume")

  -- 实体销毁跑 finally
  sim = GameSim.new({ dt = 0.05 })
  local fin = false
  local ent = sim:spawn_entity("e")
  local life = Cont.withEnv(function(_ENV)
    function work(_)
      return fx.wait(5) >> function(_) return Cont.unit(1) end
    end
    function finally(outcome)
      fin = outcome.status == "stopped" and outcome.reason == "entity_destroyed"
      return true
    end
  end)
  flow = sim:start_flow(ent, life(nil))
  sim:tick(0.05)
  sim:destroy_entity(ent.id)
  assert_true(flow.done and flow.result.stopped, "entity destroy stopped")
  assert_true(fin, "entity destroy runs finally")

  -- when_all 游戏时间并行
  sim = GameSim.new({ dt = 0.05 })
  r = sim:run(fx.when_all({
    fx.wait(0.2) >> function(_) return Cont.unit(1) end,
    fx.wait(0.4) >> function(_) return Cont.unit(2) end,
  }))
  assert_true(r.ok and r.value[1] == 1 and r.value[2] == 2, "when_all game values")
  assert_true(sim:now() >= 0.4 - 1e-9 and sim:now() < 0.55, "when_all game time ~ max")
end


------------------------------------------------------------
-- 工程能力：注册表 / 未知 kind Failed / with_resource / trace / bind_entity
------------------------------------------------------------
do
  local fx = require("fx")
  local Cont = require("cont")
  local Coro = require("coro")
  local GameSim = require("game_sim")
  local Registry = require("fx_registry")
  local Flow = require("fx_flow")

  -- 清理全局注册，避免污染其它用例
  Registry.clear()
  fx.set_tracer(nil)

  -- register / unregister
  fx.register("ping", function(req)
    return { pong = req.n or 0 }
  end)
  assert_true(Registry.has("ping"), "registry has ping")
  local r = fx.run(Coro.yield({ kind = "ping", n = 3 }) >> function(v)
    return Cont.unit(v)
  end, { wait = function() return true end })
  assert_true(r.ok and r.value.pong == 3, "fx.register handler used")
  assert_true(fx.unregister("ping"), "unregister ping")
  assert_true(not Registry.has("ping"), "ping gone")

  -- 未知 kind → Failed（非静默、非 Lua assert 崩）
  local unk = fx.run(Coro.yield({ kind = "no_such_effect_xyz" }) >> function(v)
    return Cont.unit(v)
  end, { wait = function() return true end })
  assert_true(unk.failed, "unknown kind failed")
  assert_true(type(unk.error) == "table" and unk.error.tag == "unknown_effect",
    "unknown kind structured error")
  assert_eq(unk.error.effect_kind, "no_such_effect_xyz", "unknown effect_kind")

  -- STANDARD_KINDS 文档键存在
  assert_true(Registry.STANDARD_KINDS.wait ~= nil, "STANDARD_KINDS.wait")
  assert_true(Registry.STANDARD_KINDS.wait_event ~= nil, "STANDARD_KINDS.wait_event")
  assert_true(Registry.STANDARD_KINDS.anim ~= nil, "STANDARD_KINDS.anim")

  -- with_resource：Done 路径 release
  local released = {}
  local body = fx.with_resource(
    function() return { id = "R1" } end,
    function(res)
      return Cont.unit(res.id .. ":used")
    end,
    function(res, outcome)
      released[#released + 1] = { id = res.id, status = outcome.status }
      return true
    end
  )
  r = fx.run(body, { wait = function() return true end })
  assert_true(r.ok and r.value == "R1:used", "with_resource done value")
  assert_eq(#released, 1, "with_resource release once")
  assert_eq(released[1].status, "done", "with_resource release on done")

  -- with_resource：Failed 路径仍 release
  released = {}
  body = fx.with_resource(
    function() return { id = "R2" } end,
    function(_res)
      return fx.fail("boom")
    end,
    function(res, outcome)
      released[#released + 1] = { id = res.id, status = outcome.status, err = outcome.error }
      return true
    end
  )
  r = fx.run(body, { wait = function() return true end })
  assert_true(r.failed and r.error == "boom", "with_resource fail propagates")
  assert_eq(#released, 1, "with_resource release on fail")
  assert_eq(released[1].status, "failed", "release status failed")

  -- with_resource：Stopped（cancel）仍 release
  released = {}
  local token = { cancelled = false }
  body = fx.with_resource(
    function() return { id = "R3" } end,
    function(_res)
      return fx.wait(0.05) >> function(_)
        return Cont.unit("late")
      end
    end,
    function(res, outcome)
      released[#released + 1] = { id = res.id, status = outcome.status, reason = outcome.reason }
      return true
    end
  )
  -- 用瞬时 wait handler，但 cancel 在第一次 pump 前触发较难；改用 GameSim cancel
  local sim = GameSim.new({ dt = 0.05 })
  local flow = sim:start_flow(nil, body)
  assert_true(not flow.done, "resource wait pending")
  flow.cancel("user_cancel")
  assert_true(flow.done and flow.result.stopped, "resource cancelled")
  assert_eq(#released, 1, "with_resource release on stop")
  assert_eq(released[1].status, "stopped", "release status stopped")

  -- Cont.bracket 别名
  released = {}
  r = fx.run(Cont.bracket(
    function() return 1 end,
    function(n) return Cont.unit(n + 1) end,
    function(_n, outcome)
      released[#released + 1] = outcome.status
      return true
    end
  ), { wait = function() return true end })
  assert_true(r.ok and r.value == 2 and released[1] == "done", "Cont.bracket works")

  -- 嵌套 bracket：内层 release 先于外层
  local nest_log = {}
  r = fx.run(Cont.bracket(
    function() return "outer" end,
    function(_o)
      return Cont.bracket(
        function() return "inner" end,
        function(_i) return Cont.unit(42) end,
        function(res, outcome)
          nest_log[#nest_log + 1] = res .. ":" .. outcome.status
          return true
        end
      )
    end,
    function(res, outcome)
      nest_log[#nest_log + 1] = res .. ":" .. outcome.status
      return true
    end
  ), { wait = function() return true end })
  assert_true(r.ok and r.value == 42, "nested bracket value")
  assert_eq(nest_log[1], "inner:done", "nested bracket inner first")
  assert_eq(nest_log[2], "outer:done", "nested bracket outer second")

  -- 轻量追踪
  local events = {}
  fx.set_tracer(function(ev)
    events[#events + 1] = ev.type
  end)
  r = fx.run(
    fx.wait(0.001) >> function(_) return Cont.unit(9) end,
    { wait = function() return true end }
  )
  fx.set_tracer(nil)
  assert_true(r.ok and r.value == 9, "trace run ok")
  local joined = table.concat(events, ",")
  assert_true(joined:find("flow_start", 1, true), "trace flow_start")
  assert_true(joined:find("yield", 1, true), "trace yield")
  assert_true(joined:find("done", 1, true), "trace done")

  -- opts.trace 覆盖全局
  events = {}
  r = fx.run(Cont.unit(1), { wait = function() return true end }, {
    trace = function(ev) events[#events + 1] = ev.type end,
  })
  assert_true(r.ok, "opts.trace run")
  assert_true(#events >= 2, "opts.trace events")

  -- bind_entity
  sim = GameSim.new({ dt = 0.05 })
  local ent = sim:spawn_entity("mob")
  flow = Flow.start_flow(
    fx.wait(5) >> function(_) return Cont.unit(1) end,
    nil,
    { scheduler = sim }
  )
  local binding = fx.bind_entity(flow, ent, { on_destroy = "cancel" })
  assert_eq(#ent.flows, 1, "bind appends flows")
  sim:tick(0.05)
  binding.destroy("entity_destroyed")
  assert_true(flow.done and flow.result.stopped, "bind_entity destroy cancels")

  Registry.clear()
  fx.set_tracer(nil)
end


------------------------------------------------------------
-- 地牢突袭 demo：校验 Cont/fx/GameSim 综合栈
------------------------------------------------------------
do
  package.path = "examples/dungeon_raid/?.lua;" .. package.path
  local DungeonRaid = require("dungeon")

  local r = DungeonRaid.run_focus("pause")
  assert_true(r.ok, "dungeon focus pause")

  r = DungeonRaid.run_focus("finally")
  assert_true(r.ok, "dungeon focus finally")

  r = DungeonRaid.run_focus("chests")
  assert_true(r.ok, "dungeon focus chests")

  r = DungeonRaid.run_focus("boss_interrupt")
  assert_true(r.ok, "dungeon focus boss_interrupt")

  r = DungeonRaid.run_focus("boss_timeout")
  assert_true(r.ok, "dungeon focus boss_timeout")

  -- 缩短完整通关（安静 + assert）
  r = DungeonRaid.run({ quiet = true, assert = true, seed = 1 })
  assert_true(r.ok and r.victory, "dungeon full victory")
  assert_true(r.checks.pause_deferred, "dungeon pause_deferred")
  assert_true(r.checks.mob_finally, "dungeon mob_finally")
  assert_true(r.checks.chests_parallel, "dungeon chests_parallel")
  assert_eq(r.boss_path, "interrupt", "dungeon boss_path interrupt")
  assert_true(r.hp > 0 and r.rooms >= 3, "dungeon hp/rooms")
  local c = r.checks
  assert_true(c.berserker_enraged or c.shaman_interrupted or c.assassin_ambush,
    "dungeon complex AI flag")
end


------------------------------------------------------------
-- 护卫任务 / 工人池 demo smoke（安静 assert）
------------------------------------------------------------
do
  package.loaded["escort"] = nil
  package.loaded["escort_world"] = nil
  package.path = "examples/escort_mission/?.lua;" .. package.path
  local EscortMission = require("escort")
  local r = EscortMission.run({ quiet = true, assert = true, seed = 1 })
  assert_true(r.ok and r.victory, "escort full victory")
  assert_true(r.checks.pause_deferred, "escort pause_deferred")
  assert_true(r.checks.enemy_finally, "escort enemy_finally")
  assert_true(r.checks.hud_proxy, "escort hud_proxy")
  assert_true(r.checks.lanes_used, "escort lanes")
  assert_true(r.checks.checkpoint_chan and r.checks.alert_chan, "escort chan")
  assert_true(r.checks.ambush_supervise_failed and r.checks.ambush_supervised,
    "escort supervise")
  assert_true(r.checks.rescue_ok, "escort rescue")
end

do
  package.loaded["workers"] = nil
  package.path = "examples/worker_pool/?.lua;" .. package.path
  local WorkerPool = require("workers")
  local r = WorkerPool.run({ quiet = true, assert = true, seed = 1 })
  assert_true(r.ok and r.victory, "worker_pool victory")
  assert_true(r.checks.backpressure, "worker_pool backpressure")
  assert_true(r.checks.flaky_failed and r.checks.flaky_recovered,
    "worker_pool supervise")
  assert_true(r.checks.map_parallel and r.checks.all_done, "worker_pool lanes/map")
  assert_true(r.produced >= 8 and r.results >= 8, "worker_pool counts")
end


------------------------------------------------------------
-- fx_api 按 API 示例冒烟（in-process，quiet）
------------------------------------------------------------
do
  io.stdout:write("fx_api examples... ")
  package.path = "examples/fx_api/?.lua;" .. package.path
  -- 清掉可能残留的同名模块
  for _, name in ipairs({
    "_common", "main", "wait", "wait_event", "wait_until", "wait_real",
    "stop_abort_fail", "fork_join", "when_all_any", "chan", "with_timeout",
    "supervise", "register", "run_trace", "with_resource", "seq", "lane",
    "proxy", "map_parallel", "connect_click",
  }) do
    package.loaded[name] = nil
  end
  local FxApi = require("main")
  local failed = 0
  for _, name in ipairs(FxApi.ALL) do
    package.loaded[name] = nil
    local ok, err = pcall(FxApi.run_one, name, true)
    if not ok then
      failed = failed + 1
      io.stderr:write("fx_api/" .. name .. ": " .. tostring(err) .. "\n")
    end
  end
  assert_true(failed == 0, "fx_api all examples quiet")
end


------------------------------------------------------------
-- FrameScheduler / fx.wait_until
------------------------------------------------------------
do
  local fx = require("fx")
  local Scheduler = require("scheduler")
  local Sched = require("fx_sched")
  local GameSim = require("game_sim")
  -- FrameScheduler：timer + tick
  local clock = Scheduler.FrameScheduler()
  local fired = false
  clock.schedule(0.3, function() fired = true end)
  clock.tick(0.2)
  assert_true(not fired and math.abs(clock.now() - 0.2) < 1e-12, "FrameScheduler before due")
  clock.tick(0.1)
  assert_true(fired and math.abs(clock.now() - 0.3) < 1e-9, "FrameScheduler timer due")

  -- wait_until + FrameScheduler
  clock = Scheduler.FrameScheduler()
  local n = 0
  local flow = Sched.start_session(
    fx.wait_until(function()
      n = n + 1
      if n >= 3 then return "ready" end
      return false
    end),
    {},
    { scheduler = clock }
  )
  assert_true(not flow.done and n == 1, "wait_until parks after immediate false")
  clock.tick(1 / 30)
  assert_true(not flow.done and n == 2, "wait_until poll tick1")
  clock.tick(1 / 30)
  assert_true(flow.done and flow.result.ok and flow.result.value == "ready",
    "wait_until FrameScheduler done")
  assert_true(n == 3, "wait_until poll count")

  -- opts.interval：跳过未到间隔的 tick
  clock = Scheduler.FrameScheduler()
  local checks = 0
  flow = Sched.start_session(
    fx.wait_until(function()
      checks = checks + 1
      return clock.now() >= 0.25 and clock.now()
    end, { interval = 0.1 }),
    {},
    { scheduler = clock }
  )
  clock.tick(0.05)
  local c_after = checks
  clock.tick(0.04) -- 未到 next_at
  assert_true(checks == c_after, "wait_until interval skips early tick")
  clock.tick(0.2)
  assert_true(flow.done and flow.result.ok and flow.result.value >= 0.25 - 1e-9,
    "wait_until interval eventually")

  -- cancel 清除 poll
  clock = Scheduler.FrameScheduler()
  flow = Sched.start_session(
    fx.wait_until(function() return false end),
    {},
    { scheduler = clock }
  )
  assert_true(clock.pending_polls() == 1, "pending poll")
  flow.cancel("stop-poll")
  assert_true(flow.done and flow.result.stopped, "cancel wait_until")
  assert_true(clock.pending_polls() == 0, "poll cleared on cancel")

  -- VirtualClock：无 schedule_poll 时用 schedule 轮询模拟
  clock = Scheduler.VirtualClock()
  n = 0
  flow = Sched.start_session(
    fx.wait_until(function()
      n = n + 1
      return n >= 3 and "via-sched"
    end),
    {},
    { scheduler = clock }
  )
  clock.advance(0)
  assert_true(not flow.done, "VirtualClock wait_until pending")
  clock.advance(0)
  assert_true(flow.done and flow.result.ok and flow.result.value == "via-sched",
    "VirtualClock wait_until via schedule")

  -- GameSim.tick + wait_until
  local sim = GameSim.new({ dt = 0.05 })
  local r = sim:run(
    fx.wait_until(function()
      return sim:now() >= 0.2 and sim:now()
    end)
  )
  assert_true(r.ok and r.value >= 0.2 - 1e-9, "GameSim wait_until value")
  assert_true(sim:now() >= 0.2 - 1e-9 and sim:now() < 0.35, "GameSim wait_until time")

  -- with_timeout + wait_until
  clock = Scheduler.FrameScheduler()
  flow = Sched.start_session(
    fx.with_timeout(fx.wait_until(function() return false end), 0.15),
    {},
    { scheduler = clock }
  )
  clock.tick(0.1)
  assert_true(not flow.done, "timeout wait_until still waiting")
  clock.tick(0.06)
  assert_true(flow.done and flow.result.failed and flow.result.error == "timeout",
    "timeout beats wait_until")
  assert_true(clock.pending_polls() == 0, "poll cleared on timeout")

  -- pred 抛错 → Failed
  clock = Scheduler.FrameScheduler()
  local first = true
  flow = Sched.start_session(
    fx.wait_until(function()
      if first then first = false; return false end
      error("pred-boom")
    end),
    {},
    { scheduler = clock }
  )
  clock.tick(0.01)
  assert_true(flow.done and flow.result.failed, "pred error Failed")
  assert_true(tostring(flow.result.error):find("pred-boom", 1, true) ~= nil,
    "pred error message")

  -- STANDARD_KINDS.wait_until
  local Registry = require("fx_registry")
  assert_true(Registry.STANDARD_KINDS.wait_until ~= nil, "STANDARD_KINDS.wait_until")
end




------------------------------------------------------------
-- 0.2.3-eng：abort / iquit / seq / suspend
------------------------------------------------------------
do
  io.stdout:write("abort/iquit/seq/suspend... ")
  local fx = require("fx")
  local Sched = require("fx_sched")
  local Scheduler = require("scheduler")
  local GameSim = require("game_sim")
  local cont_env = require("cont_env")
  -- withEnv(_ENV) 会遮蔽全局；钩子内请用外层 upvalue
  local tostring = tostring

  -- Coro.Aborted
  local a = Coro.start(Coro.abort("x"))
  assert_true(Coro.isAborted(a) and a.reason == "x", "coro abort Answer")
  local st, payload = Coro.runEx(Coro.abort("y"), function() end)
  assert_eq(st, "aborted", "coro runEx aborted")
  assert_eq(payload, "y", "coro runEx aborted reason")

  -- fork 子 abort → join 失败（aborted），finally 已跑
  local log = {}
  local child = Cont.withEnv(function(_ENV)
    function step(_)
      return fx.wait(0.01) >> function(_)
        return fx.abort("child-boom")
      end
    end
    function finally(outcome)
      log[#log + 1] = "f:" .. tostring(outcome.status)
    end
  end)
  local parent = fx.fork(child(nil)) >> function(h)
    return fx.join(h)
  end
  local clock = Scheduler.VirtualClock()
  local flow = Sched.start_session(parent, {}, { scheduler = clock })
  clock.advance(0.02)
  assert_true(flow.done, "abort join done")
  assert_true(flow.result.aborted and flow.result.reason == "child-boom",
    "abort join → aborted")
  assert_eq(log[1], "f:aborted", "child finally on abort")

  -- when_all 子 abort → 传播
  local r_wa = fx.run(fx.when_all({
    Cont.unit(1),
    fx.abort("wa-abort"),
  }), { wait = function() return true end })
  assert_true(r_wa.aborted and r_wa.reason == "wa-abort", "when_all abort")

  -- iquit 在 cancel 时先于 finally；Done 跳过 iquit
  log = {}
  local pipe = Cont.withEnv(function(_ENV)
    function step(x)
      return Coro.yield({ kind = "wait", seconds = 1 }) >> function(_)
        return Cont.unit(x)
      end
    end
    function iquit(outcome)
      log[#log + 1] = "iq:" .. tostring(outcome.status)
    end
    function finally(outcome)
      log[#log + 1] = "f:" .. tostring(outcome.status)
    end
  end)
  local ans = Coro.start(pipe(0))
  assert_true(Coro.isYielded(ans), "iquit pipe yielded")
  ans = Coro.force_stop(ans, "cancelled")
  assert_true(Coro.isStopped(ans), "force_stop Stopped")
  assert_eq(log[1], "iq:stopped", "iquit before finally")
  assert_eq(log[2], "f:stopped", "finally after iquit")

  log = {}
  local ok_pipe = Cont.withEnv(function(_ENV)
    function step(x) return x + 1 end
    function iquit(outcome)
      log[#log + 1] = "iq"
    end
    function finally(outcome)
      log[#log + 1] = "f:" .. tostring(outcome.status)
    end
  end)
  assert_eq(Cont.evalCont(ok_pipe(1)), 2, "iquit skip on done value")
  assert_eq(#log, 1, "iquit skipped on Done")
  assert_eq(log[1], "f:done", "finally on Done")

  -- Cont.iquit_finally API
  log = {}
  local m = Cont.iquit_finally(
    Coro.abort("z"),
    function(o) log[#log + 1] = "iq:" .. o.status end,
    function(o) log[#log + 1] = "f:" .. o.status end
  )
  st, payload = Coro.runEx(m, function() end)
  assert_eq(st, "aborted", "iquit_finally status")
  assert_eq(log[1], "iq:aborted", "iquit_finally iquit first")
  assert_eq(log[2], "f:aborted", "iquit_finally finally second")

  -- fx.seq
  local r_seq = fx.run(fx.seq({
    Cont.unit(1) >> function(x) return Cont.unit(x + 1) end,
    Cont.unit(10) >> function(x) return Cont.unit(x + 5) end,
  }), {})
  assert_true(r_seq.ok and r_seq.value == 15, "fx.seq last value")
  local r_empty = fx.run(fx.seq({}), {})
  assert_true(r_empty.ok and r_empty.value == nil, "fx.seq empty → nil")

  -- 顺序：seq 左到右执行副作用
  log = {}
  local function mark(n)
    return Cont.wrap(function(k)
      log[#log + 1] = n
      return k(n)
    end)
  end
  r_seq = fx.run(fx.seq({ mark(1), mark(2), mark(3) }), {})
  assert_true(r_seq.ok and r_seq.value == 3, "fx.seq mark value")
  assert_eq(log[1], 1, "seq order1")
  assert_eq(log[2], 2, "seq order2")
  assert_eq(log[3], 3, "seq order3")

  -- suspend 冻结 wait，resume 继续（VirtualClock / FrameScheduler）
  clock = Scheduler.VirtualClock()
  flow = Sched.start_session(fx.wait(0.5) >> function(_)
    return Cont.unit("awake")
  end, {}, { scheduler = clock })
  assert_true(not flow.done, "suspend wait pending")
  flow.suspend()
  assert_true(flow.is_suspended(), "is_suspended")
  clock.advance(0.6)
  assert_true(not flow.done, "suspended: wait not fired")
  flow.resume()
  assert_true(flow.done and flow.result.ok and flow.result.value == "awake",
    "resume continues wait")

  -- GameSim:suspend_flow / resume_flow
  local sim = GameSim.new({ dt = 0.05 })
  flow = sim:start_flow(nil, fx.wait(0.2) >> function(_)
    return Cont.unit(true)
  end)
  sim:suspend_flow(flow)
  for _ = 1, 10 do sim:tick(0.05) end
  assert_true(not flow.done, "GameSim suspend freezes")
  sim:resume_flow(flow)
  assert_true(flow.done and flow.result.ok, "GameSim resume continues")

  assert_true(type(cont_env.with_iquit) == "function", "cont_env.with_iquit")
  assert_true(type(fx.abort) == "function" and type(fx.seq) == "function", "fx.abort/seq")

  io.stdout:write("ok\n")
end

------------------------------------------------------------
-- fx.run / start_session：无 Yield 同步快路径
------------------------------------------------------------
do
  io.stdout:write("sync fast-path... ")
  local Cont = require("cont")
  local fx = require("fx")
  local Sched = require("fx_sched")

  local r = fx.run(fx.seq({ Cont.unit(1), Cont.unit(2), Cont.unit(3) }), {})
  assert_true(r.ok and r.value == 3, "sync seq×3")

  r = fx.run(fx.fail("boom"), {})
  assert_true(r.failed and r.error == "boom", "sync fail")

  r = fx.run(fx.stop("bye"), {})
  assert_true(r.stopped and r.reason == "bye", "sync stop")

  -- cancel 优先（与 pump 一致；Cont 已求值）
  r = fx.run(Cont.unit(1), {}, { cancel = { cancelled = true } })
  assert_true(r.stopped and r.reason == "cancelled", "sync cancel preempt")

  local log = {}
  r = fx.run(Cont.finally(Cont.unit(7), function()
    log[#log + 1] = "f"
  end), {})
  assert_true(r.ok and r.value == 7 and log[1] == "f", "sync finally on Done")

  local ev = {}
  r = fx.run(Cont.unit(1), {}, {
    trace = function(e) ev[#ev + 1] = e.type end,
  })
  assert_true(r.ok, "sync trace ok")
  assert_eq(table.concat(ev, ","), "flow_start,done", "sync trace events")

  -- Yield 仍走完整 session
  local flow = Sched.start_session(
    fx.wait(0.01) >> function(_) return Cont.unit(9) end,
    { wait = function() return true end },
    {}
  )
  assert_true(flow.done and flow.result.ok and flow.result.value == 9, "yield still session")
  assert_true(flow.nursery ~= nil, "yield path has nursery")

  -- 同步 settled flow 无 nursery
  flow = Sched.start_session(Cont.unit(1), {}, {})
  assert_true(flow.done and flow.result.ok, "settled flow done")
  assert_true(flow.nursery == nil, "sync path no nursery")

  io.stdout:write("ok\n")
end


------------------------------------------------------------
-- fx：有界 channel / mailbox（P2）
------------------------------------------------------------
do
  io.stdout:write("fx.chan... ")
  local Cont = require("cont")
  local fx = require("fx")
  local GameSim = require("game_sim")
  local Registry = require("fx_registry")

  assert_true(fx.CHAN_DEFAULT_CAPACITY == 1, "default capacity 1")
  assert_true(Registry.STANDARD_KINDS.chan_send ~= nil, "STANDARD_KINDS.chan_send")
  assert_true(Registry.STANDARD_KINDS.chan_recv ~= nil, "STANDARD_KINDS.chan_recv")
  assert_true(Registry.STANDARD_KINDS.chan_close ~= nil, "STANDARD_KINDS.chan_close")

  -- fork 内 send/recv（默认可缓冲 1）
  local ch = fx.chan()
  local r = fx.run(
    fx.fork(fx.send(ch, "ping") >> function()
      return Cont.unit(true)
    end) >> function(h)
      return fx.recv(ch) >> function(v)
        return fx.join(h) >> function()
          return Cont.unit(v)
        end
      end
    end
  )
  assert_true(r.ok and r.value == "ping", "fork send/recv")

  -- 缓冲：先发后收
  ch = fx.chan(2)
  r = fx.run(
    fx.send(ch, 1) >> function()
      return fx.send(ch, 2) >> function()
        return fx.recv(ch) >> function(a)
          return fx.recv(ch) >> function(b)
            return Cont.unit({ a, b })
          end
        end
      end
    end
  )
  assert_true(r.ok and r.value[1] == 1 and r.value[2] == 2, "buffered send then recv")

  -- GameSim：满则挂起，peer recv 后唤醒（无 busy_wait）
  local sim = GameSim.new({ dt = 0.05 })
  ch = fx.chan(1)
  local wall0 = os.clock()
  local sdone, vals
  local fs = sim:start_flow(nil,
    fx.send(ch, "A") >> function()
      return fx.send(ch, "B") >> function()
        sdone = true
        return Cont.unit(true)
      end
    end
  )
  sim:tick(0)
  assert_true(not fs.done and #ch.buf == 1 and #ch.send_q == 1, "send blocks when full")
  local fr = sim:start_flow(nil,
    fx.recv(ch) >> function(a)
      return fx.recv(ch) >> function(b)
        vals = { a, b }
        return Cont.unit(true)
      end
    end
  )
  sim:tick(0)
  assert_true(fs.done and fr.done and sdone, "peer unblocks")
  assert_true(vals[1] == "A" and vals[2] == "B", "GameSim order")
  assert_true(os.clock() - wall0 < 0.05, "no busy_wait on chan")

  -- 跨 flow
  sim = GameSim.new({ dt = 0.05 })
  ch = fx.chan(1)
  local got
  local frecv = sim:start_flow(nil, fx.recv(ch) >> function(v)
    got = v
    return Cont.unit(v)
  end)
  assert_true(not frecv.done, "cross-flow recv pending")
  local fsend = sim:start_flow(nil, fx.send(ch, 99))
  sim:tick(0)
  assert_true(frecv.done and fsend.done and got == 99, "cross-flow deliver")

  -- cancel 清除 waiter → Stopped
  sim = GameSim.new({ dt = 0.05 })
  ch = fx.chan(1)
  local flow = sim:start_flow(nil, fx.recv(ch))
  assert_true(#ch.recv_q == 1, "recv queued")
  flow.cancel("cancelled")
  assert_true(flow.done and flow.result.stopped, "cancel Stopped")
  assert_eq(#ch.recv_q, 0, "cancel clears recv_q")

  sim = GameSim.new({ dt = 0.05 })
  ch = fx.chan(0)
  flow = sim:start_flow(nil, fx.send(ch, "x"))
  assert_true(#ch.send_q == 1, "send queued cap0")
  flow.cancel()
  assert_true(flow.result.stopped and #ch.send_q == 0, "cancel clears send_q")

  -- close：等待 recv → Failed chan_closed；缓冲仍可读
  sim = GameSim.new({ dt = 0.05 })
  ch = fx.chan(2)
  r = sim:run(fx.send(ch, "keep") >> function()
    return fx.close(ch)
  end)
  assert_true(r.ok and fx.is_closed(ch), "close ok")
  r = sim:run(fx.recv(ch))
  assert_true(r.ok and r.value == "keep", "recv after close drains buf")
  r = sim:run(fx.recv(ch))
  assert_true(r.failed and r.error.tag == "chan_closed", "recv empty closed")
  r = sim:run(fx.send(ch, 1))
  assert_true(r.failed and r.error.tag == "chan_closed", "send on closed")

  -- 容量 0 会合
  sim = GameSim.new({ dt = 0.05 })
  ch = fx.chan(0)
  local rv
  frecv = sim:start_flow(nil, fx.recv(ch) >> function(v)
    rv = v
    return Cont.unit(v)
  end)
  fsend = sim:start_flow(nil, fx.send(ch, "Z"))
  sim:tick(0)
  assert_true(frecv.done and fsend.done and rv == "Z" and #ch.buf == 0, "rendezvous cap0")

  io.stdout:write("ok\n")
end


------------------------------------------------------------
-- fx：supervise 监督式重启（P2）
------------------------------------------------------------
do
  io.stdout:write("fx.supervise... ")
  local Cont = require("cont")
  local fx = require("fx")
  local Scheduler = require("scheduler")
  local Registry = require("fx_registry")
  local GameSim = require("game_sim")

  assert_true(Registry.STANDARD_KINDS.supervise ~= nil, "STANDARD_KINDS.supervise")
  assert_true(type(fx.supervise) == "function", "fx.supervise exists")

  -- 首次成功
  local r = fx.run(fx.supervise(Cont.unit(42)))
  assert_true(r.ok and r.value == 42, "supervise first-try ok")

  -- Failed 后重启直至成功（默认 max_restarts=3）
  local n = 0
  local child = Cont.unit(nil) >> function()
    n = n + 1
    if n < 3 then
      return fx.fail("e" .. n)
    end
    return Cont.unit("ok" .. n)
  end
  r = fx.run(fx.supervise(child))
  assert_true(r.ok and r.value == "ok3" and n == 3, "supervise restart then ok")

  -- 超过 max_restarts → 表面 Failed
  n = 0
  child = Cont.unit(nil) >> function()
    n = n + 1
    return fx.fail("boom")
  end
  r = fx.run(fx.supervise(child, { max_restarts = 2 }))
  assert_true(r.failed and r.error == "boom" and n == 3,
    "max_restarts=2 → 3 attempts then Failed")

  -- max_restarts=0：不重启
  n = 0
  child = Cont.unit(nil) >> function()
    n = n + 1
    return fx.fail("once")
  end
  r = fx.run(fx.supervise(child, { max_restarts = 0 }))
  assert_true(r.failed and n == 1, "max_restarts=0 no restart")

  -- restart_if / on_fail 抑制重启
  n = 0
  child = Cont.unit(nil) >> function()
    n = n + 1
    return fx.fail("nope")
  end
  r = fx.run(fx.supervise(child, {
    max_restarts = 5,
    restart_if = function() return false end,
  }))
  assert_true(r.failed and n == 1, "restart_if false")

  local seen = {}
  n = 0
  child = Cont.unit(nil) >> function()
    n = n + 1
    return fx.fail("e")
  end
  r = fx.run(fx.supervise(child, {
    max_restarts = 5,
    on_fail = function(err)
      seen[#seen + 1] = err
      return false
    end,
  }))
  assert_true(r.failed and n == 1 and seen[1] == "e", "on_fail false")

  -- Stopped 默认不重启；restart_on_stop 可开
  n = 0
  child = Cont.unit(nil) >> function()
    n = n + 1
    return fx.stop("bye")
  end
  r = fx.run(fx.supervise(child, { max_restarts = 5 }))
  assert_true(r.stopped and n == 1, "Stopped no restart by default")

  n = 0
  child = Cont.unit(nil) >> function()
    n = n + 1
    if n < 2 then
      return fx.stop("retry-me")
    end
    return Cont.unit("after-stop")
  end
  r = fx.run(fx.supervise(child, { max_restarts = 3, restart_on_stop = true }))
  assert_true(r.ok and r.value == "after-stop" and n == 2, "restart_on_stop")

  -- Aborted 不重启
  n = 0
  child = Cont.unit(nil) >> function()
    n = n + 1
    return fx.abort("ab")
  end
  r = fx.run(fx.supervise(child, { max_restarts = 5 }))
  assert_true(r.aborted and n == 1, "Aborted no restart")

  -- 游戏时间 backoff（VirtualClock）
  local clock = Scheduler.VirtualClock()
  n = 0
  child = Cont.unit(nil) >> function()
    n = n + 1
    if n < 3 then
      return fx.fail("x")
    end
    return Cont.unit(n)
  end
  local flow = fx.sched.start_session(
    fx.supervise(child, { max_restarts = 3, backoff = 0.5 }),
    {},
    { scheduler = clock }
  )
  assert_true(not flow.done and n == 1, "backoff pending after fail")
  clock.advance(0.4)
  assert_true(not flow.done and n == 1, "backoff not due yet")
  clock.advance(0.2)
  assert_true(n == 2, "second attempt after backoff")
  clock.advance(1.0)
  assert_true(flow.done and flow.result.ok and flow.result.value == 3,
    "backoff supervise completes")

  -- cancel 当前子：不重启
  n = 0
  child = Cont.unit(nil) >> function()
    n = n + 1
    return fx.wait(10)
  end
  clock = Scheduler.VirtualClock()
  flow = fx.sched.start_session(
    fx.supervise(child, { max_restarts = 5 }),
    {},
    { scheduler = clock }
  )
  flow.cancel("cancelled")
  assert_true(flow.result.stopped and n == 1, "cancel child no restart")

  -- cancel 在 backoff 期间：不启下一轮
  local starts = 0
  child = Cont.unit(nil) >> function()
    starts = starts + 1
    return fx.fail("x")
  end
  clock = Scheduler.VirtualClock()
  flow = fx.sched.start_session(
    fx.supervise(child, { max_restarts = 5, backoff = 1.0 }),
    {},
    { scheduler = clock }
  )
  assert_true(starts == 1 and not flow.done, "in backoff")
  flow.cancel("cancelled")
  assert_true(flow.result.stopped, "cancel during backoff Stopped")
  clock.advance(2.0)
  assert_eq(starts, 1, "no restart after cancel during backoff")

  -- finally / iquit：每次 Failed 尝试都跑；成功跳过 iquit
  local cleaned = 0
  n = 0
  child = Cont.finally(
    Cont.unit(nil) >> function()
      n = n + 1
      if n < 2 then
        return fx.fail("f")
      end
      return Cont.unit("S")
    end,
    function()
      cleaned = cleaned + 1
      return true
    end
  )
  r = fx.run(fx.supervise(child, { max_restarts = 3 }))
  assert_true(r.ok and r.value == "S" and cleaned == 2 and n == 2,
    "finally each attempt")

  local order = {}
  n = 0
  child = Cont.iquit_finally(
    Cont.unit(nil) >> function()
      n = n + 1
      if n < 2 then
        return fx.fail("z")
      end
      return Cont.unit("Y")
    end,
    function()
      order[#order + 1] = "iquit"
      return true
    end,
    function()
      order[#order + 1] = "finally"
      return true
    end
  )
  r = fx.run(fx.supervise(child, { max_restarts = 3 }))
  assert_true(r.ok and r.value == "Y", "iquit_finally value")
  assert_eq(table.concat(order, ","), "iquit,finally,finally",
    "iquit then finally on fail; finally only on success")

  -- GameSim：supervise + backoff 游戏时间
  local sim = GameSim.new({ dt = 0.1 })
  n = 0
  child = Cont.unit(nil) >> function()
    n = n + 1
    if n < 2 then
      return fx.fail("retry")
    end
    return Cont.unit("gs")
  end
  flow = sim:start_flow(nil, fx.supervise(child, { max_restarts = 3, backoff = 0.3 }))
  assert_true(not flow.done and n == 1, "GameSim backoff pending")
  sim:tick(0.2)
  assert_true(not flow.done and n == 1, "GameSim before backoff due")
  sim:tick(0.2)
  assert_true(flow.done and flow.result.ok and flow.result.value == "gs" and n == 2,
    "GameSim supervise ok")

  io.stdout:write("ok\n")
end



------------------------------------------------------------
-- fx.wait_real（opt-in 墙钟；默认 Failed）
------------------------------------------------------------
do
  io.stdout:write("fx.wait_real… ")
  local fx = require("fx")
  local Cont = require("cont")
  local Registry = require("fx_registry")
  local Scheduler = require("scheduler")

  assert_true(Registry.STANDARD_KINDS.wait_real ~= nil, "STANDARD_KINDS.wait_real")

  -- 默认：无 schedule_real、无 allow_real_time → Failed 清晰
  local r = fx.run(fx.wait_real(0.01) >> function(_)
    return Cont.unit("should-not")
  end)
  assert_true(r.failed, "wait_real default failed")
  assert_true(type(r.error) == "table" and r.error.tag == "wait_real_unsupported",
    "wait_real default tag")
  assert_eq(r.error.effect_kind, "wait_real", "wait_real effect_kind")

  -- VirtualClock / MockUnityHost：仅有 schedule，无 schedule_real → 仍 Failed
  local clock = Scheduler.VirtualClock()
  r = fx.run(fx.wait_real(0.5), nil, { scheduler = clock })
  assert_true(r.failed and r.error.tag == "wait_real_unsupported",
    "VirtualClock wait_real unsupported")

  package.path = "host/unity/?.lua;" .. package.path
  local Mock = require("MockUnityHost")
  local host, pump = Mock.with_virtual()
  local LuaGameScheduler = require("LuaGameScheduler")
  local sched = LuaGameScheduler.adapt(host)
  assert_true(sched.schedule_real == nil, "Mock host has no schedule_real")
  r = fx.run(fx.wait_real(0.2), nil, { scheduler = sched })
  assert_true(r.failed and r.error.tag == "wait_real_unsupported",
    "MockUnityHost wait_real unsupported")
  -- pump 不应误醒（本来就 Failed，无 timer）
  pump(1.0)

  -- allow_real_time 路径：busy_wait 兑现（短延迟）
  r = fx.run(fx.wait_real(0.02) >> function(_)
    return Cont.unit(true)
  end, nil, { allow_real_time = true })
  assert_true(r.ok and r.value == true, "allow_real_time wait_real ok")

  -- schedule_real 路径：注入简易墙钟队列（不依赖真实 sleep）
  local real_q = {}
  local real_now = 0
  local host2 = {
    now = function() return 0 end,
    schedule = function(delay, cb)
      return { kind = "scaled", delay = delay, cb = cb }
    end,
    cancel = function(h)
      if h then h.cancelled = true end
    end,
    schedule_real = function(delay, cb)
      local h = { cancelled = false, due = real_now + (delay or 0), cb = cb }
      real_q[#real_q + 1] = h
      return h
    end,
  }
  local S = LuaGameScheduler.adapt(host2)
  assert_true(type(S.schedule_real) == "function", "adapt forwards schedule_real")
  local Boot = require("FxUnityBootstrap")
  local api = Boot.bootstrap(host2)
  local flow = api.start_session(fx.wait_real(0.3) >> function(_)
    return Cont.unit("real")
  end)
  assert_true(not flow.done, "wait_real pending via schedule_real")
  assert_true(#real_q == 1, "one real timer")
  -- 推进「墙钟」并触发
  real_now = 0.3
  local h = real_q[1]
  if not h.cancelled then h.cb() end
  assert_true(flow.done and flow.result.ok and flow.result.value == "real",
    "schedule_real resumes")

  -- Bootstrap 自动填 scheduler（VirtualClock + wait）
  local host3, pump3 = Mock.with_virtual()
  local api3 = Boot.bootstrap(host3)
  local done = false
  local f3 = api3.start_session(fx.wait(0.25) >> function(_)
    done = true
    return Cont.unit(1)
  end)
  assert_true(not f3.done, "bootstrap wait pending")
  pump3(0.25)
  assert_true(f3.done and f3.result.ok and done, "bootstrap wires scheduler")

  io.stdout:write("ok\n")
end



------------------------------------------------------------
-- fx：命名 lane（轻量 tabMachine 多行）
------------------------------------------------------------
do
  io.stdout:write("fx.lane... ")
  local Cont = require("cont")
  local fx = require("fx")
  local Registry = require("fx_registry")
  local sched = require("fx_sched")

  assert_true(Registry.STANDARD_KINDS.lane ~= nil, "STANDARD_KINDS.lane")
  assert_true(type(fx.lane) == "function", "fx.lane exists")
  assert_true(type(fx.lanes) == "function", "fx.lanes exists")

  -- lane + lane_join
  local r = fx.run(
    fx.lane("t1", Cont.unit(7)) >> function(h)
      assert_eq(h.name, "t1", "handle.name")
      return fx.lane_join("t1")
    end
  )
  assert_true(r.ok and r.value == 7, "lane+join value")

  -- lanes map 汇合
  r = fx.run(fx.lanes({
    s = Cont.unit("S"),
    t = Cont.unit("T"),
  }))
  assert_true(r.ok and r.value.s == "S" and r.value.t == "T", "lanes map")

  -- 并行 wall：两路 wait 经 lanes
  local t0 = sched.now()
  r = fx.run(fx.lanes({
    a = fx.wait(0.04) >> function(_) return Cont.unit(1) end,
    b = fx.wait(0.04) >> function(_) return Cont.unit(2) end,
  }))
  local elapsed = sched.now() - t0
  assert_true(r.ok and r.value.a == 1 and r.value.b == 2, "lanes parallel vals")
  assert_true(elapsed < 0.075, "lanes wall < 0.075 got " .. tostring(elapsed))

  -- lane_stop 后 join → Stopped
  r = fx.run(
    fx.lane("slow", fx.wait(1.0) >> function(_) return Cont.unit("no") end) >> function(_)
      return fx.lane_stop("slow", "bye") >> function(stopped)
        assert_true(stopped == true, "lane_stop was running")
        return fx.lane_join("slow")
      end
    end
  )
  assert_true(r.stopped and r.reason == "bye", "lane_stop → join Stopped")

  -- lane_abort → join Aborted
  r = fx.run(
    fx.lane("bad", fx.wait(1.0) >> function(_) return Cont.unit("x") end) >> function(_)
      return fx.lane_abort("bad", "kaboom") >> function(aborted)
        assert_true(aborted == true, "lane_abort was running")
        return fx.lane_join("bad")
      end
    end
  )
  assert_true(r.aborted and r.reason == "kaboom", "lane_abort → join Aborted")

  -- 同名在跑 → lane_busy
  r = fx.run(
    fx.lane("dup", fx.wait(0.5) >> function(_) return Cont.unit(1) end) >> function(_)
      return fx.lane("dup", Cont.unit(2))
    end
  )
  assert_true(r.failed and type(r.error) == "table" and r.error.tag == "lane_busy",
    "lane_busy")

  -- 未知名 join → lane_unknown
  r = fx.run(fx.lane_join("nope"))
  assert_true(r.failed and type(r.error) == "table" and r.error.tag == "lane_unknown",
    "lane_unknown")

  -- stop 无名 → false，父仍成功
  r = fx.run(fx.lane_stop("ghost") >> function(ok)
    return Cont.unit(ok)
  end)
  assert_true(r.ok and r.value == false, "lane_stop unknown → false")

  -- 结束后可复用同名
  r = fx.run(
    fx.lane("reuse", Cont.unit("first")) >> function(_)
      return fx.lane_join("reuse") >> function(v1)
        return fx.lane("reuse", Cont.unit("second")) >> function(_)
          return fx.lane_join("reuse") >> function(v2)
            return Cont.unit({ v1, v2 })
          end
        end
      end
    end
  )
  assert_true(r.ok and r.value[1] == "first" and r.value[2] == "second", "reuse name")

  io.stdout:write("ok\n")
end





------------------------------------------------------------
-- fx：轻量 proxy（tabMachine tabProxy 对照）
------------------------------------------------------------
do
  io.stdout:write("fx.proxy... ")
  local Cont = require("cont")
  local fx = require("fx")
  local Registry = require("fx_registry")
  local Sched = require("fx_sched")
  local Scheduler = require("scheduler")

  assert_true(Registry.STANDARD_KINDS.proxy_join ~= nil, "STANDARD_KINDS.proxy_join")
  assert_true(type(fx.proxy) == "function", "fx.proxy exists")
  assert_true(type(fx.proxy_join) == "function", "fx.proxy_join exists")

  -- name proxy + join
  local r = fx.run(
    fx.lane("t1", Cont.unit(7)) >> function(_)
      return fx.proxy_join(fx.proxy("t1"))
    end
  )
  assert_true(r.ok and r.value == 7, "proxy name join")

  -- handle proxy
  r = fx.run(
    fx.fork(Cont.unit(42)) >> function(h)
      local p = fx.proxy(h)
      assert_true(p._is_proxy and p.id == h.id, "proxy from handle")
      return fx.proxy_join(p)
    end
  )
  assert_true(r.ok and r.value == 42, "proxy handle join")

  -- proxy_stop → Stopped
  r = fx.run(
    fx.lane("slow", fx.wait(1.0) >> function(_) return Cont.unit("no") end) >> function(_)
      local p = fx.proxy("slow")
      return fx.proxy_stop(p, "bye") >> function(ok)
        assert_true(ok == true, "proxy_stop was running")
        return fx.proxy_join(p)
      end
    end
  )
  assert_true(r.stopped and r.reason == "bye", "proxy_stop → Stopped")

  -- proxy_abort → Aborted
  r = fx.run(
    fx.lane("bad", fx.wait(1.0) >> function(_) return Cont.unit("x") end) >> function(_)
      return fx.proxy_abort(fx.proxy("bad"), "kaboom") >> function(ok)
        assert_true(ok == true, "proxy_abort was running")
        return fx.proxy_join(fx.proxy("bad"))
      end
    end
  )
  assert_true(r.aborted and r.reason == "kaboom", "proxy_abort → Aborted")

  -- unknown
  r = fx.run(fx.proxy_join(fx.proxy("nope")))
  assert_true(r.failed and type(r.error) == "table" and r.error.tag == "proxy_unknown",
    "proxy_unknown")

  -- stop unknown → false
  r = fx.run(fx.proxy_stop(fx.proxy("ghost")) >> function(ok)
    return Cont.unit(ok)
  end)
  assert_true(r.ok and r.value == false, "proxy_stop unknown → false")

  -- flow:proxy 跨 session（VirtualClock）
  local clock = Scheduler.VirtualClock()
  local flow = Sched.start_session(
    fx.wait(0.05) >> function(_) return Cont.unit("done") end,
    {},
    { scheduler = clock }
  )
  assert_true(type(flow.proxy) == "function", "flow.proxy method")
  local p = flow:proxy()
  assert_true(p._is_proxy and p.flow == flow, "flow:proxy shape")
  local waiter = Sched.start_session(
    fx.proxy_join(p) >> function(v) return Cont.unit(v) end,
    {},
    { scheduler = clock }
  )
  assert_true(not flow.done and not waiter.done, "both pending")
  clock.advance(0.1)
  assert_true(flow.done and flow.result.ok, "host flow done")
  assert_true(waiter.done and waiter.result.ok and waiter.result.value == "done",
    "cross-session proxy_join")

  -- stop_host_when_stop：取消等待方 → 停 host flow
  clock = Scheduler.VirtualClock()
  flow = Sched.start_session(
    fx.wait(5.0) >> function(_) return Cont.unit("late") end,
    {},
    { scheduler = clock }
  )
  waiter = Sched.start_session(
    fx.proxy_join(flow:proxy({ stop_host_when_stop = true })),
    {},
    { scheduler = clock }
  )
  waiter.cancel("leave")
  assert_true(waiter.done and waiter.result.stopped, "waiter cancelled")
  assert_true(flow.done and flow.result.stopped
      and flow.result.reason == "proxy_stop_host",
    "stop_host_when_stop")

  -- proxy_stop 整段 flow
  clock = Scheduler.VirtualClock()
  flow = Sched.start_session(
    fx.wait(5.0) >> function(_) return Cont.unit("x") end,
    {},
    { scheduler = clock }
  )
  local stopper = Sched.start_session(
    fx.proxy_stop(flow:proxy(), "halt") >> function(ok) return Cont.unit(ok) end,
    {},
    { scheduler = clock }
  )
  assert_true(stopper.done and stopper.result.ok and stopper.result.value == true,
    "proxy_stop flow ok")
  assert_true(flow.done and flow.result.stopped and flow.result.reason == "halt",
    "flow halted by proxy_stop")

  io.stdout:write("ok\n")
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
