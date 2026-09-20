-- do_coro.lua — 用原生 coroutine 组织顺序 do（方案 B）
--
-- 用户代码写成「顺序」而不手写 >>；底层仍由 monad 的 bind 驱动。
-- 仅把 Lua 原生 coroutine 当作实现细节；与 Cont CPS 协程（coro.lua）完全分离。
--
-- 典型用法：
--   local do_coro = require("do_coro")
--   local foo = do_coro.runDo(Maybe, function()
--     local x = do_coro.perform(Maybe.Just(3))
--     local y = do_coro.perform(Maybe.Just("!"))
--     return Maybe.Just(tostring(x) .. y)
--   end)
-- 或（已挂薄包装的模块）：Maybe.runDo(function() ... end)
--
-- 注意：body 最终须 return 一个 monadic 值（对照 Haskell do 末行）。
-- 多结果 monad（如 List 的 nondeterminism）无法在单条 coroutine 上正确「分叉」；
-- 本机制适合 Maybe / Status / Identity / Reader / Writer / State 等「单路径 bind」。

local do_coro = {}

-- 仅在 runDo 创建的 body 协程内有效：挂起并把 ma 交给外层 bind。
-- 恢复时得到未包装的纯值 a（即 bind 续函数收到的那个 a）。
-- 命名 perform，避免与 Coro.yield / coroutine.yield 在文档与心智上混淆。
function do_coro.perform(ma)
  local co, ismain = coroutine.running()
  -- Lua 5.1：running() 在主线程返回 nil；5.2+：返回 thread, ismain
  if co == nil or ismain then
    error("perform: only valid inside runDo", 2)
  end
  return coroutine.yield(ma)
end

-- 解析 bind：可传 bind 函数，或带 .bind 的 monad 模块表。
local function resolve_bind(bind_or_M)
  if type(bind_or_M) == "function" then
    return bind_or_M
  end
  if type(bind_or_M) == "table" and type(bind_or_M.bind) == "function" then
    return bind_or_M.bind
  end
  error("runDo: expected bind function or monad module with .bind", 2)
end

-- runDo(M, body) 或 runDo(bind, body)
-- 驱动模式（经典）：
--   resume → yield ma → bind(ma, step) → resume(a) → … → dead 时返回 body 的 monadic 结果
function do_coro.runDo(bind_or_M, body)
  assert(type(body) == "function", "runDo: body must be a function")
  local bind = resolve_bind(bind_or_M)
  local co = coroutine.create(body)

  local function step(x)
    local ok, y = coroutine.resume(co, x)
    if not ok then
      error(y)
    end
    if coroutine.status(co) == "dead" then
      return y -- body 返回的最终 monadic 值
    end
    -- y 是 perform 挂起的 ma
    return bind(y, step)
  end

  -- 首次 resume：无参 / nil；body 通常以 perform 开头
  return step()
end

-- 给模块挂薄包装：M.runDo(body) ≡ runDo(M, body)；不改动其它字段。
function do_coro.attach(M)
  assert(type(M) == "table" and type(M.bind) == "function",
    "attach: expected monad module with .bind")
  M.runDo = function(body)
    return do_coro.runDo(M, body)
  end
  return M
end

-- 别名：install == attach（测试 / 示例里可 do_coro.install(Maybe)）
do_coro.install = do_coro.attach

return do_coro
