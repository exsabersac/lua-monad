-- writer.lua — Writer 单子（附带可拼接日志）
--
-- 对应 Haskell Control.Monad.Writer：
--   Writer w a  ≈  (a, w)  ，其中 w 是 monoid
-- 本库默认 w 为 string（mempty=""，mappend=..）；
-- 也可用 makeWriter({ mempty, mappend }) / withMonoid 定制，
-- 或用 WriterList（表列表 monoid：{} + 数组拼接）。
--
-- 值形状：{ value = a, log = w }
-- 辅助：tell / listen / pass / runWriter / execWriter。

local monad = require("monad")

-- monoid: { mempty = w0, mappend = function(w1, w2) → w }
local function makeWriter(monoid)
  assert(type(monoid) == "table", "makeWriter: monoid table required")
  assert(monoid.mempty ~= nil, "makeWriter: mempty required")
  assert(type(monoid.mappend) == "function", "makeWriter: mappend required")

  local mempty = monoid.mempty
  local mappend = monoid.mappend

  local function unit(a)
    return { value = a, log = mempty }
  end

  -- bind：左右日志按 monoid 左到右拼接
  local function bind(ma, f)
    local mb = f(ma.value)
    return {
      value = mb.value,
      log = mappend(ma.log, mb.log),
    }
  end

  local M = monad.makeMonad({
    unit = unit,
    bind = bind,
  })

  M.mempty = mempty
  M.mappend = mappend

  -- 追加一段日志；结果值为 nil
  function M.tell(w)
    return M.wrap({ value = nil, log = w })
  end

  -- listen：结果变为 { value=a, log=w }，日志本身不变
  function M.listen(ma)
    local raw = M.unwrap(ma)
    return M.wrap({
      value = { value = raw.value, log = raw.log },
      log = raw.log,
    })
  end

  -- pass：ma 的 value 为 { a, f } 或 { value=a, fn=f }，
  -- 用 f(log) 改造最终日志，结果值为 a
  function M.pass(ma)
    local raw = M.unwrap(ma)
    local pair = raw.value
    local a, f
    if type(pair) == "table" and pair.fn ~= nil then
      a, f = pair.value, pair.fn
    else
      a, f = pair[1], pair[2]
    end
    assert(type(f) == "function", "pass: expected (a, w→w) pair")
    return M.wrap({
      value = a,
      log = f(raw.log),
    })
  end

  -- → value, log
  function M.runWriter(ma)
    local raw = M.unwrap(ma)
    return raw.value, raw.log
  end

  function M.execWriter(ma)
    local _, w = M.runWriter(ma)
    return w
  end

  -- 顺序 do（原生 coroutine）：见 do_coro.lua / docs/顺序do_coro.md
  M.runDo = function(body)
    return require("do_coro").runDo(M, body)
  end

  return M
end

-- 默认：字符串 monoid
local Writer = makeWriter({
  mempty = "",
  mappend = function(a, b)
    return a .. b
  end,
})

-- 表列表 monoid
local WriterList = makeWriter({
  mempty = {},
  mappend = function(a, b)
    local out = {}
    for _, x in ipairs(a) do
      out[#out + 1] = x
    end
    for _, x in ipairs(b) do
      out[#out + 1] = x
    end
    return out
  end,
})

Writer.makeWriter = makeWriter
Writer.withMonoid = makeWriter
Writer.WriterList = WriterList

return Writer
