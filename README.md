# Lua Monad 模拟库

在纯 Lua 中模拟 Haskell 风格的 **Monad**，并用 **Cont（续延）** 实现基于 CPS 的协程（非 Lua 原生 `coroutine`）。

## `m` 在 Lua 里是什么？

Haskell 里常写 `m a`（「装在 monad `m` 里的 `a`」）。本库用一张普通 Lua table 表示某个 monad 实例，习惯上命名为 `m` 或模块名（`Maybe`、`List`…）：

| 字段 | 含义 |
|------|------|
| `m.unit(a)` / `m.return_` / `m.pure` | 把普通值放进 monad（Haskell 的 `return` / `pure`） |
| `m.bind(ma, f)` | 绑定：`ma >>= f`（`f` 返回同种 monad） |
| `m.then_(ma, f)` | 映射：约等于 `fmap`（默认用 `bind`+`unit` 实现） |

工厂函数：

```lua
local monad = require("monad")
local m = monad.makeMonad({ unit = ..., bind = ... })
```

## 元表符号糖

`makeMonad` 会给 monadic 值挂上共享元表，支持更接近 Haskell 的写法（需 **Lua 5.3+ / 5.4**）：

| 语法 | 元方法 | 含义 |
|------|--------|------|
| `ma >> f` | `__shr` | `m.bind(ma, f)`（Haskell `>>=`） |
| `ma .. mb` | `__concat` | 先跑 `ma` 再丢弃其结果，得到 `mb`（Haskell `>>`） |
| `Maybe(x)` | 模块 `__call` | 等价于 `Maybe.unit(x)` |

- **表形** monad（Maybe / List / Status）：直接在值表上 `setmetatable`，保留 `tag`、`value`、数组部分等字段。
- **函数形** monad（Cont / State）：包成可调用代理 `{ _fn = f }`（`__call` 转发）；`runCont` / `runState` 等会自动 `unwrap`。也可用 `m.unwrap` / `m.wrap`。

示例：

```lua
local Maybe = require("maybe")
local Cont = require("cont")

-- Maybe：绑定与顺序
local r = Maybe.Just(2) >> function(x)
  return Maybe.Just(x * 3)
end
-- r.tag == "just", r.value == 6

local s = Maybe.Just(1) .. Maybe.Just(99)   -- 丢弃左边，得到 Just(99)
local n = Maybe.Nothing() .. Maybe.Just(99) -- Nothing 短路

-- 模块当构造器
assert(Maybe(7).value == 7)

-- Cont
local v = Cont.runCont(
  Cont.unit(2) >> function(x) return Cont.unit(x + 3) end,
  function(x) return x * 10 end
)  -- 50
```

原有的 `bind` / `then_` / `map` API 不变。

## 各实例

### Maybe — 可失败计算

```lua
{ tag = "just", value = v }   -- Just v
{ tag = "nothing" }           -- Nothing
```

`Nothing` 会短路后续 `bind`。

### List — 非确定性 / 多结果

用 Lua **数组**；`bind` 对每个元素应用 `f` 再 **展平**。

### State — 带状态的计算

表示成 `function(s) return a, s end`（对外为可调用代理）。

辅助：`get` / `put` / `modify` / `runState` / `evalState` / `execState`。

### Status（Result）— 成功或错误

```lua
{ tag = "ok",  value = v }
{ tag = "err", error = e }
```

`Err` 短路，类似 Maybe，但携带错误信息。

### Cont — 续延 monad

`Cont r a ≈ (a → r) → r`，在 Lua 里就是「接受续延 `k` 的函数」（对外为可调用代理）：

```lua
unit(a)      = function(k) return k(a) end
bind(ma, f)  = function(k) return ma(function(a) return f(a)(k) end) end
```

## Cont → CPS 协程

`src/coro.lua` 在 Cont 之上实现**单路** CPS 协程（不是 `coroutine.create`）：

| 答案类型 | 形状 |
|----------|------|
| `Done` | `{ tag="done", value }` |
| `Yielded` | `{ tag="yielded", value, cont }` |

API：

- `Coro.yield(v)` — 挂起并交出 `v`；`resume` 时把新值送回
- `Coro.start(ma)` — 以「最终值包成 Done」为顶层续延启动
- `Coro.resume(y, b)` — 把 `b` 喂给挂起的 `cont`

适合教学：看清「yield = 捕获当前续延」的本质。也可与 Cont 的 `>>` 混用。

## 如何运行

需要 Lua 5.4+（本机可用 `lua` 或 `lua5.4`）。

```bash
cd /workspace/lua-monad

# 测试（失败则非零退出）
lua tests/run.lua

# 演示
lua examples/demo.lua

# LYAH Walk the line（Maybe 走钢丝）
lua examples/walk_the_line.lua
```

`package.path` 已在脚本里加上 `src/?.lua`，请在**仓库根目录**执行。

## 目录

```
lua-monad/
  src/monad.lua    # makeMonad + 元表符号糖
  src/maybe.lua
  src/list.lua
  src/state.lua
  src/status.lua
  src/cont.lua
  src/coro.lua     # Cont-based CPS coro
  tests/run.lua
  examples/demo.lua
  examples/walk_the_line.lua  # LYAH Maybe 示例
  README.md
```

## 许可

教学示例，随意使用。
