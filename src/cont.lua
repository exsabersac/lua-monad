-- cont.lua — Cont 续延单子
--
-- Cont r a ≈ (a → r) → r
-- 即「接受最终续延 k，算出类型为 r 的答案」。
-- 本库用 function(k) ... end 表示；wrap 成可调用代理后仍可 ma(k)。
--
--   unit(a)     = λk. k(a)
--   bind(ma, f) = λk. ma(λa. f(a)(k))
--
-- callCC 捕获当前续延，用于提前跳出；runCont / evalCont 以用户续延执行。
-- mapCont / withCont 分别改造「答案」与「续延本身」。
-- reset / shift 提供教学用的定界续延（答案类型需自洽）。
-- coro.lua 建立在 Cont 之上，用答案类型 Done|Yielded|Stopped|Failed 模拟挂起与中止。
-- throw / catch / protect 提供 Cont 层显式异常（handler 栈，不用 Lua error 传业务失败）。

local monad = require("monad")

local function unit(a)
  return function(k)
    return k(a)
  end
end

local function bind(ma, f)
  return function(k)
    return ma(function(a)
      return f(a)(k)
    end)
  end
end

local M = monad.makeMonad({
  unit = unit,
  bind = bind,
})

-- callCC : ((a → Cont r b) → Cont r a) → Cont r a
--
-- 经典「以当前续延为逃逸出口」：
--   f 收到 escape；调用 escape(a) 会忽略 escape 之后的一切续延，
--   直接把 a 交给「进入 callCC 当时」的外层 k。
--
-- 典型用法（提前返回 / abort 风格）：
--   Cont.callCC(function(escape)
--     return Cont.unit(1) >> function(_)
--       return escape(42) >> function(_)   -- 后面不会执行
--         return Cont.unit(999)
--       end
--     end
--   end)
--   经 evalCont 得到 42。
--
-- 注意：escape(a) 返回的仍是 Cont 值，可参与 bind/>>；但其内部会丢弃后续 k2。
function M.callCC(f)
  return M.wrap(function(k)
    local function escape(a)
      return M.wrap(function(_k2)
        return k(a)
      end)
    end
    return M.unwrap(f(escape))(k)
  end)
end

-- runCont : Cont r a → (a → r) → r
-- 以用户提供的最终续延 k 执行计算。
function M.runCont(ma, k)
  return M.unwrap(ma)(k)
end

-- evalCont : Cont a a → a
-- 用恒等续延取出答案（要求答案类型与值类型一致，或 k 恒等可接受）。
function M.evalCont(ma)
  return M.runCont(ma, function(x)
    return x
  end)
end

-- mapCont : (r → r) → Cont r a → Cont r a
-- Haskell（transformers Cont）：mapCont f (Cont c) = Cont (f . c)
-- 即改造「整段计算产出的答案 r」，不改续延的形态：
--   λk. f(c(k))
-- 与 withCont 对比：mapCont 作用在结果上；withCont 作用在续延函数上。
function M.mapCont(f, ma)
  local c = M.unwrap(ma)
  return M.wrap(function(k)
    return f(c(k))
  end)
end

-- withCont : ((b → r) → (a → r)) → Cont r a → Cont r b
-- Haskell：withCont f (Cont c) = Cont (c . f)
-- 即用 f 变换「即将交给计算的续延」：
--   λk. c(f(k))
-- 其中 f :: (b → r) → (a → r)，可把期望 b 的续延改写成期望 a 的续延。
--
-- 与 mapCont 的区别（务必分清）：
--   mapCont f m  = Cont (f ∘ runCont m)     —— f 包在「跑完之后」的答案外
--   withCont f m = Cont (runCont m ∘ f)     —— f 包在「续延参数」上再交给 m
-- 二者参数 f 的类型也不同：mapCont 的 f 是 r→r；withCont 的 f 是续延变换器。
function M.withCont(f, ma)
  local c = M.unwrap(ma)
  return M.wrap(function(k)
    return c(f(k))
  end)
end

-- reset : Cont a a → a
-- 定界续延的「提示」：在恒等续延下跑完 Cont（与 evalCont 相同）。
-- 类型上要求 Cont a a（答案类型与最终值类型一致）。
function M.reset(ma)
  return M.evalCont(ma)
end

-- shift : ((a → Cont r r) → Cont r r) → Cont r a
-- 捕获「reset 以内、shift 以外」的定界续延 k，交给 f。
-- f 收到的 k 满足：evalCont(k(x)) ≡ 把 x 喂给定界续延后的答案。
--
-- 经典小例子（答案为 number）：
--   reset( shift(λk. unit(evalCont(k(3)) + evalCont(k(4)))) >>= λx. unit(x*2) )
--   定界续延是 λx. x*2，故得 6+8 = 14。
function M.shift(f)
  return M.wrap(function(k)
    local function captured(x)
      return M.wrap(function(k2)
        return k2(k(x))
      end)
    end
    return M.evalCont(f(captured))
  end)
end


------------------------------------------------------------
-- throw / catch / protect（显式失败，handler 栈；教学用）
------------------------------------------------------------
-- catch 向栈顶压入「逃逸续延」；throw 忽略当前 k，直接调用栈顶 handler。
-- catch 同时用 pcall 兜住 ma 内的 Lua error，一并交给 handler。

local catch_stack = {}

-- throw : e → Cont r a
-- 逃逸到最近 Cont.catch；无 catch 则 error（未捕获）
-- 调用 handler 前先弹出栈顶，使 handler 内再 throw 落到外层 catch
function M.throw(err)
  return M.wrap(function(_k)
    local n = #catch_stack
    local top = catch_stack[n]
    if not top then
      error("uncaught Cont.throw: " .. tostring(err), 0)
    end
    catch_stack[n] = nil
    return top(err)
  end)
end

-- catch : Cont r a → (e → Cont r a) → Cont r a
-- handler(err) 返回 Cont，用外层续延 k 继续
function M.catch(ma, handler)
  assert(type(handler) == "function", "Cont.catch: handler must be a function")
  return M.wrap(function(k)
    local function handle(err)
      return M.unwrap(handler(err))(k)
    end
    catch_stack[#catch_stack + 1] = handle
    local ok, res = pcall(function()
      return M.unwrap(ma)(k)
    end)
    -- 成功路径或未走 throw 时仍在栈上则弹出；throw 已自行弹出
    if catch_stack[#catch_stack] == handle then
      catch_stack[#catch_stack] = nil
    end
    if not ok then
      return handle(res)
    end
    return res
  end)
end

-- protect : Cont r a → Cont r a
-- 用 pcall 包住 ma；Lua error 若有 catch 则走 throw 路径，否则以 {tag="error", error=...} 交给 k
function M.protect(ma)
  return M.wrap(function(k)
    local ok, res = pcall(function()
      return M.unwrap(ma)(k)
    end)
    if ok then
      return res
    end
    local n = #catch_stack
    local top = catch_stack[n]
    if top then
      catch_stack[n] = nil -- 与 throw 相同：先弹出再进 handler
      return top(res)
    end
    return k({ tag = "error", error = res })
  end)
end

-- withEnv / finally / init_finally：延迟加载 cont_env，避免循环 require。
-- 首次调用后会被替换为真正实现（cont_env 加载时也会挂载到 Cont）。
function M.withEnv(body)
  local ce = require("cont_env")
  M.withEnv = ce.withEnv
  M.finally = ce.with_finally
  M.init_finally = ce.init_finally
  return ce.withEnv(body)
end

function M.finally(ma, cleanup)
  local ce = require("cont_env")
  M.withEnv = ce.withEnv
  M.finally = ce.with_finally
  M.init_finally = ce.init_finally
  return ce.with_finally(ma, cleanup)
end

function M.init_finally(ma, init, cleanup)
  local ce = require("cont_env")
  M.withEnv = ce.withEnv
  M.finally = ce.with_finally
  M.init_finally = ce.init_finally
  return ce.init_finally(ma, init, cleanup)
end

return M
