# API 参考

约定：`ma` 表示该模块的 monadic 值；未特别说明时，`unit`/`bind` 的返回值已 `wrap`，可使用 `>>` / `..`。

路径：从仓库根目录 `require` 时需 `package.path` 含 `src/?.lua`（测试与示例脚本已设置）。

---

## `monad` — `src/monad.lua`

### `monad.makeMonad(spec) → m`

| 字段 | 必填 | 说明 |
|------|------|------|
| `spec.unit` | 是 | `a → 裸 monadic 值` |
| `spec.bind` | 是 | `(裸 ma, a → 裸 mb) → 裸 mb` |
| `spec.then_` | 否 | 自定义 fmap；缺省由 `bind`+`unit` 导出 |

返回的模块表 `m` 含：

| 成员 | 说明 |
|------|------|
| `m.unit(a)` / `m.return_` / `m.pure` | 包装并 `wrap` |
| `m.bind(ma, f)` | 绑定；内部 `unwrap` 后再 `wrap` |
| `m.then_(ma, f)` / `m.fmap` / `m.map` | `m a → (a → b) → m b` |
| `m.wrap(x)` / `m.unwrap(x)` | 显式包装 / 拆代理 |
| `m(x)` | 等价于 `m.unit(x)` |

值上的运算符：`ma >> f`、`ma .. mb`；函数形还可 `ma(...)`。

---

## `Maybe` — `src/maybe.lua`

值形状：`{ tag="just", value }` | `{ tag="nothing" }`。

| 函数 | 说明 |
|------|------|
| `Just(v)` / `unit(v)` / `Maybe(v)` | `Just v` |
| `Nothing()` | `Nothing`（已 wrap） |
| `bind` / `then_` / … | 见 `makeMonad`；`Nothing` 短路 |
| `isJust(m)` / `isNothing(m)` | 谓词 |
| `fromJust(m)` | 取 `value`；非 Just 则 assert |

---

## `List` — `src/list.lua`

值形状：Lua 数组（可带本模块元表）。

| 函数 | 说明 |
|------|------|
| `unit(x)` / `singleton(x)` / `List(x)` | `{ x }` |
| `bind(xs, f)` | 对每个元素 `f` 再展平 |
| `wrap(t)` | 给已有数组挂元表（继承自 `makeMonad`） |
| `concat(xss)` | 展平一层并 wrap |
| `empty()` | `{}` |

---

## `Status` — `src/status.lua`

值形状：`{ tag="ok", value }` | `{ tag="err", error }`。

| 函数 | 说明 |
|------|------|
| `Ok(v)` / `unit(v)` / `Status(v)` | 成功 |
| `Err(e)` | 失败（已 wrap） |
| `bind` | `Err` 原样短路 |
| `isOk(r)` / `isErr(r)` | 谓词 |

---

## `State` — `src/state.lua`

裸值：`function(s) return a, s end`；对外多为 `{ _fn = f }` 代理。

| 函数 | 说明 |
|------|------|
| `unit(a)` / `State(a)` | 不改状态，结果为 `a` |
| `bind` | 串联状态线程 |
| `get()` | 结果与状态皆为当前 `s` |
| `put(s_new)` | 覆盖状态；结果 `nil` |
| `modify(f)` | `s ← f(s)`；结果 `nil` |
| `runState(ma, s0)` | → `a, s` |
| `evalState(ma, s0)` | → `a` |
| `execState(ma, s0)` | → `s` |

---

## `Cont` — `src/cont.lua`

裸值：`function(k) … end`，`k :: a → r`；对外为可调用代理。

| 函数 | 说明 |
|------|------|
| `unit(a)` / `Cont(a)` | `λk. k(a)` |
| `bind(ma, f)` | `λk. ma(λa. f(a)(k))` |
| `runCont(ma, k)` | 以续延 `k` 执行 → `r` |
| `evalCont(ma)` | `runCont(ma, id)`；答案类型需与值可对齐 |
| `mapCont(f, ma)` | `(r→r) → Cont r a → Cont r a`；`λk. f(c(k))`，改造**答案** |
| `withCont(f, ma)` | `((b→r)→(a→r)) → Cont r a → Cont r b`；`λk. c(f(k))`，改造**续延** |
| `callCC(f)` | `f(escape)`；`escape(a)` 跳出到进入 callCC 时的外层续延（abort 风格） |
| `reset(ma)` | 定界提示：等同 `evalCont(ma)`（`Cont a a → a`） |
| `shift(f)` | 定界捕获：`f` 收到 `k`，`evalCont(k(x))` 为定界续延作用于 `x` |

`mapCont` vs `withCont`：前者 `f` 包在跑完之后的结果上；后者 `f` 先变换续延再交给计算。示例见 `examples/cont_cps_basics.lua`、`examples/cont_callcc.lua`。

---

## `Coro` — `src/coro.lua`

建立在 `Cont` 上；答案类型为 `Done | Yielded`。

| 函数 | 说明 |
|------|------|
| `Done(v)` / `Yielded(v, cont)` | 构造答案 |
| `isDone(a)` / `isYielded(a)` | 谓词 |
| `yield(v)` | → `Cont Answer b`；挂起并交出 `v` |
| `start(ma)` | 跑 Cont，顶层续延包成 `Done` |
| `resume(y, b)` | 将 `b` 喂给 `y.cont` |
| `step(answer, value)` | Done 原样返回；Yielded 则 `resume` |
| `run(ma, handler)` | 循环：Yielded 时 `handler(yielded)` 得 resume 输入；返回最终 Done 值 |
| `collect(ma)` | 记录每次 yield 载荷，resume 用 `true`；→ `yields, final` |
| `Coro.Cont` | 对 `cont` 模块的引用 |

典型循环（手动）：

```lua
local step = Coro.start(body)
while Coro.isYielded(step) do
  step = Coro.resume(step, reply)
  -- 或：step = Coro.step(step, reply)
end
-- step.tag == "done"
```

驱动助手：`Coro.run` / `Coro.collect`（见 `examples/coro_generator.lua`、`examples/coro_interactive.lua`）。

---

## `mdo` — `src/mdo.lua`（do-notation 预处理）

将 `@mdo MONAD … @end` 展开为 `>>` / `..` 嵌套。详见 [`do语法.md`](do语法.md)。

| 函数 | 说明 |
|------|------|
| `expand(body_src, monad[, base_line])` | 展开 do 正文 → Lua 表达式字符串；`monad` 为上下文名 |
| `preprocess(file_src)` | 替换源码中全部 `@mdo` 块，返回完整 Lua 源 |

CLI：`lua tools/mdo.lua INPUT.mdo [-o OUTPUT.lua]`（默认同路径 `.lua`）。
