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

表示成 `function(s) return a, s end`。

辅助：`get` / `put` / `modify` / `runState` / `evalState` / `execState`。

### Status（Result）— 成功或错误

```lua
{ tag = "ok",  value = v }
{ tag = "err", error = e }
```

`Err` 短路，类似 Maybe，但携带错误信息。

### Cont — 续延 monad

`Cont r a ≈ (a → r) → r`，在 Lua 里就是「接受续延 `k` 的函数」：

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

适合教学：看清「yield = 捕获当前续延」的本质。

## 如何运行

需要 Lua 5.4+（本机可用 `lua` 或 `lua5.4`）。

```bash
cd /workspace/lua-monad

# 测试（失败则非零退出）
lua tests/run.lua

# 演示
lua examples/demo.lua
```

`package.path` 已在脚本里加上 `src/?.lua`，请在**仓库根目录**执行。

## 目录

```
lua-monad/
  src/monad.lua    # makeMonad
  src/maybe.lua
  src/list.lua
  src/state.lua
  src/status.lua
  src/cont.lua
  src/coro.lua     # Cont-based CPS coro
  tests/run.lua
  examples/demo.lua
  README.md
```

## 许可

教学示例，随意使用。
