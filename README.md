# Lua Monad 模拟库

在纯 Lua 中模拟 Haskell 风格的 **Monad**，并用 **Cont（续延）** 实现基于 CPS 的协程（不是 Lua 原生 `coroutine`）。

面向教学与对照阅读：值形态、定律测试、以及 LYAH「走钢丝」示例均可在本仓库直接跑通。

更细的设计说明见 [`docs/设计说明.md`](docs/设计说明.md)；API 一览见 [`docs/API.md`](docs/API.md)；do 语法见 [`docs/do语法.md`](docs/do语法.md)。

## `m` 在 Lua 里是什么？

Haskell 里常写 `m a`（「装在 monad `m` 里的 `a`」）。本库用一张普通 Lua table 表示某个 monad **实例/模块**，习惯上命名为 `m` 或模块名（`Maybe`、`List`…）：

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

`makeMonad` 还会给产出的 monadic 值挂上共享元表，并支持 `m(x)` 作为 `m.unit(x)` 的简写。

## 元表符号糖

需 **Lua 5.3+ / 5.4**（本仓库按 5.4 测）：

| 语法 | 元方法 | 含义 |
|------|--------|------|
| `ma >> f` | `__shr` | `m.bind(ma, f)`（Haskell `>>=`） |
| `ma .. mb` | `__concat` | 先跑 `ma` 再丢弃其结果，得到 `mb`（Haskell `>>`） |
| `Maybe(x)` | 模块 `__call` | 等价于 `Maybe.unit(x)` |

值形态：

- **表形**（Maybe / List / Status）：直接在值表上 `setmetatable`，保留 `tag`、`value`、数组部分等字段。
- **函数形**（Cont / State）：包成可调用代理 `{ _fn = f }`（`__call` 转发）；`runCont` / `runState` 等会自动 `unwrap`。也可用 `m.unwrap` / `m.wrap`。

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

`Nothing` 会短路后续 `bind`。教学示例见下方「Walk the line」。

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

另有 `runCont` / `evalCont`、`mapCont` / `withCont`、`callCC`，以及教学用定界续延 `reset` / `shift`。

- `mapCont` 改造答案；`withCont` 改造续延（二者 `f` 类型不同，见 API 文档）。
- `callCC` 的 `escape` 可做提前退出（abort 风格），示例：`examples/cont_callcc.lua`。
- CPS 串联示例：`examples/cont_cps_basics.lua`。

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
- `Coro.step(answer, value)` — Done 透传；Yielded 则 resume
- `Coro.run(ma, handler)` — 自动循环，handler 提供每次 resume 输入
- `Coro.collect(ma)` — 收集全部 yield 载荷，→ `yields, final`

适合教学：看清「yield = 捕获当前续延」的本质。也可与 Cont 的 `>>` 混用。设计上的三层划分见 [`docs/设计说明.md`](docs/设计说明.md)。

生成器 / 交互示例：`examples/coro_generator.lua`、`examples/coro_interactive.lua`。

## do-notation（`@mdo` 预处理）

长 `>> function(x) return … end` 链可用类 Haskell 的 do 语法书写，由预处理器变成真正的 Lua：

```
local foo = @mdo Maybe
  x <- Maybe.Just(3)
  y <- Maybe.Just("!")
  Maybe.Just(tostring(x) .. y)
@end
```

**推荐直接执行 `.mdo`（自动预处理）：**

```bash
lua tools/mdo.lua --run examples/do_maybe_foo.mdo
lua tools/run_mdo.lua examples/do_walk_the_line.mdo   # routine → Just (3,2)
```

或写 `.lua` 后再跑：

```bash
lua tools/mdo.lua examples/do_maybe_foo.mdo   # 生成 .lua
lua examples/do_maybe_foo.lua
```

程序内：`mdo.install_loader()` 后可用 `require` 加载 `.mdo`；或 `mdo.dofile` / `mdo.loadfile`。

语法规则、限制与 API 见 [`docs/do语法.md`](docs/do语法.md)。库：`src/mdo.lua`；CLI：`tools/mdo.lua`、`tools/run_mdo.lua`。

## Walk the line（LYAH）

[`examples/walk_the_line.lua`](examples/walk_the_line.lua) 对照 *Learn You a Haskell*「A Fistful of Monads」中 Pierre 走钢丝：

- `Pole` 用 `{ left, right }`；
- `landLeft` / `landRight` / `banana` 返回 `Maybe Pole`；
- 链式用 `>>`（`>>=`），插入失败用 `..`（Haskell `>>`）。

```bash
lua examples/walk_the_line.lua
```

## 如何运行

需要 Lua 5.4+（本机可用 `lua` 或 `lua5.4`）。

```bash
cd /workspace/lua-monad   # 或你的克隆路径

# 测试（失败则非零退出）
lua tests/run.lua

# 演示
lua examples/demo.lua

# LYAH Walk the line（Maybe 走钢丝）
lua examples/walk_the_line.lua

# do-notation：直接跑 .mdo（推荐）
lua tools/mdo.lua --run examples/do_maybe_foo.mdo
lua tools/run_mdo.lua examples/do_walk_the_line.mdo
# 或只生成 .lua 再跑
lua tools/mdo.lua examples/do_maybe_foo.mdo
lua examples/do_maybe_foo.lua

# Cont / CPS 协程示例
lua examples/cont_callcc.lua
lua examples/cont_cps_basics.lua
lua examples/coro_generator.lua
lua examples/coro_interactive.lua
```

`package.path` 已在脚本里加上 `src/?.lua`，请在**仓库根目录**执行。

## 目录

```
lua-monad/
  src/monad.lua              # makeMonad + 元表符号糖
  src/maybe.lua
  src/list.lua
  src/state.lua
  src/status.lua
  src/cont.lua
  src/coro.lua               # Cont-based CPS coro
  src/mdo.lua                # @mdo 预处理 + loadfile/dofile/loader
  tests/run.lua              # 定律 + 糖 + coro + mdo 断言
  tools/mdo.lua              # CLI：写 .lua 或 --run
  tools/run_mdo.lua          # --run 薄包装
  examples/demo.lua
  examples/walk_the_line.lua   # LYAH Maybe 示例
  examples/cont_callcc.lua     # callCC 提前退出
  examples/cont_cps_basics.lua # CPS 加法/阶乘/定界续延
  examples/coro_generator.lua  # yield 1..n + collect/run
  examples/coro_interactive.lua# yield 请求 / resume 回答
  docs/设计说明.md
  docs/API.md
  docs/do语法.md
  README.md
```

## 许可

教学示例，随意使用。
