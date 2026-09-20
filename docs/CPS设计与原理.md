# CPS 设计与工作原理

本文说明本库中 **Cont（续延单子）** 与 **基于 Cont 的 CPS 协程** 的设计动机、表示方法与执行过程。实现以 `src/cont.lua`、`src/coro.lua` 为准；可配合 `examples/cont_*.lua`、`examples/coro_*.lua` 一起读。

---

## 1. 什么是 CPS？

**CPS（Continuation-Passing Style，续延传递风格）** 的意思是：函数不算「算完就返回」，而是额外接收一个参数 **续延（continuation）**——「拿到结果之后该做什么」。

直评风格：

```text
f(x)  →  直接得到结果 y
```

CPS 风格：

```text
f(x, k)  →  在内部算出 y 后调用 k(y)
```

这里的 `k` 就是续延：类型直觉是 `结果 → 最终答案`。整段程序的「最终答案」类型记为 `r`；中间步骤的值类型记为 `a`。于是一个尚未跑完的计算可以看成：

```text
Cont r a  ≈  (a → r) → r
```

读作：给我一个「如何把 `a` 变成最终答案 `r`」的函数，我交出一个 `r`。

### 为什么教学上有用？

- **控制流显式化**：提前返回、异常、协程挂起，都可以描述成「换一个续延」或「先不调用当前续延」。
- **和 Monad 同构**：`unit` / `bind` 正好描述「如何把带续延的计算串起来」，不必先引入副作用。
- **和 Lua 原生协程对照**：原生 `coroutine` 靠虚拟机保存栈；本库把「剩余工作」编码成普通 Lua 函数，便于逐步调试。

---

## 2. 本库如何表示 Cont？

### 2.1 裸值：一个吃续延的函数

```lua
-- 类型直觉：Cont r a
local ma = function(k)
  -- … 某处调用 k(某个_a) …
end
```

### 2.2 对外：可调用代理（wrap）

`makeMonad` 会把函数包成 `{ _fn = f }`，并挂上元表：

- `ma >> f` → `bind`
- `ma .. mb` → 丢弃左边结果再跑右边（Haskell `>>`）
- `ma(k)` → 仍可直接把续延传进去（`__call` 转发到 `_fn`）

`Cont.runCont(ma, k)` / `Cont.evalCont(ma)` 内部会先 `unwrap` 再调用。

### 2.3 unit 与 bind（核心等式）

```text
unit(a)      =  λk. k(a)
bind(ma, f)  =  λk. ma( λa. f(a)(k) )
```

含义：

1. **`unit(a)`**：已经有值 `a`，接到最终续延 `k` 后立刻 `k(a)`。
2. **`bind(ma, f)`**：先跑 `ma`；`ma` 成功交出中间值 `a` 时，不直接交给外层的 `k`，而是先把 `a` 交给 `f`，得到下一段 Cont `f(a)`，再把**同一个**外层 `k` 传下去。

因此 `k` 会一路传到整条链的末尾——这就是「续延在传递」。

对应源码（逻辑等价）：

```lua
unit(a)      = function(k) return k(a) end
bind(ma, f)  = function(k)
  return ma(function(a)
    return f(a)(k)
  end)
end
```

### 2.4 一条最小执行轨迹

```lua
local m = Cont.unit(2) >> function(x)
  return Cont.unit(x + 3)
end
print(Cont.evalCont(m))  -- 5
```

`evalCont` 使用恒等续延 `λx. x`。展开后直觉是：

```text
evalCont(m)
  = m(λz. z)
  = unit(2) 的 bind 结果 接到 λz.z
  = （内层）先 k1 = λx. unit(x+3)(λz.z)
  = unit(2)(k1) = k1(2)
  = unit(5)(λz.z) = 5
```

更长的加法 / 阶乘 / 勾股串联见 `examples/cont_cps_basics.lua`。

---

## 3. 跑起来：runCont 与 evalCont

| API | 含义 |
|-----|------|
| `runCont(ma, k)` | 把用户续延 `k : a → r` 交给 `ma`，得到 `r` |
| `evalCont(ma)` | `runCont(ma, λx. x)`，要求「答案类型」与值类型在恒等下可对齐 |

常见用法：

- 只要最终数字 / 字符串：用 `evalCont`。
- 协程层把答案类型换成 `Done|Yielded`：用 `runCont(ma, λa. Done(a))` 作为顶层（见下文 `start`）。

---

## 4. callCC：捕获「当前剩余工作」并逃逸

`callCC`（call with current continuation）提供一个 **escape** 出口：调用 `escape(v)` 等于「立刻把 `v` 交给进入 `callCC` 时的外层续延」，**忽略** escape 之后原本要做的事。

```lua
Cont.callCC(function(escape)
  return Cont.unit("开始") >> function(_)
    return escape(42) >> function(_)
      return Cont.unit(999)  -- 不会成为最终答案
    end
  end
end)
-- evalCont → 42
```

实现要点（与源码一致）：

```text
callCC(f) = λk.
  let escape(a) = λ_k2. k(a)    -- 丢掉之后的续延 _k2，直接用外层 k
  in  f(escape)(k)
```

这是 **非定界（undelimited）** 逃逸：出口一直通到当前 `runCont`/`evalCont` 的顶层续延。适合「找到答案就返回」「abort」等控制流。示例见 `examples/cont_callcc.lua`。

---

## 5. mapCont 与 withCont：改答案还是改续延？

二者容易混淆，类型与作用点不同。

记裸 Cont 为 `c`，即 `ma` unwrap 之后的函数。

### mapCont：包在「整段跑完的答案」外面

```text
mapCont(f, ma) = λk. f( c(k) )
```

`f : r → r`。先按原续延 `k` 跑完得到答案，再对答案做 `f`。

```lua
Cont.evalCont(Cont.mapCont(function(r) return r + 10 end, Cont.unit(5)))  -- 15
```

### withCont：先改造「即将传入的续延」

```text
withCont(f, ma) = λk. c( f(k) )
```

`f : (b → r) → (a → r)`：把「期望 `b` 的续延」变成「期望 `a` 的续延」，再交给原来的 `c`。

```lua
Cont.evalCont(Cont.withCont(function(k)
  return function(a) return k(a * 2) end
end, Cont.unit(5)))  -- 10
```

对照：

| | mapCont | withCont |
|--|---------|----------|
| 组合方向（直觉） | `f ∘ c` | `c ∘ f` |
| `f` 作用对象 | 最终答案 `r` | 续延函数本身 |
| 典型用途 | 统一改写结果 | 在值进入后续之前改写 / 适配续延 |

---

## 6. reset / shift：定界续延

有时不希望逃逸冲出整段程序，只希望截取 **某一段** 的「剩余工作」。`reset` 给出边界；`shift` 捕获边界以内的续延。

本库的教学编码：

```text
reset(ma)  ≡  evalCont(ma)          -- 以恒等为定界提示

shift(f)   =  λk.
  let captured(x) = λk2. k2( k(x) ) -- 把定界续延 k 包成 Cont
  in  evalCont( f(captured) )
```

`f` 收到的 `captured` 可以 **调用多次**（每次相当于把值送进定界续延再取结果）。

经典例子（与测试一致）：

```text
reset(
  shift(λk. unit( eval(k(3)) + eval(k(4)) ))
  >>= λx. unit(x * 2)
)
```

定界续延是「乘 2」，于是 `3*2 + 4*2 = 14`。

与 `callCC` 的对比：

| | callCC / escape | shift / reset |
|--|-----------------|---------------|
| 范围 | 直到当前顶层 run | 只到最近 reset |
| 捕获的续延 | 通常一次性逃逸 | 常可多次调用 |
| 典型问题 | 提前返回 | 局部回溯、多次填充上下文 |

---

## 7. 从 Cont 到 CPS 协程：三层设计

目标：在 **不使用** Lua `coroutine.create/yield` 的前提下，表达「算到一半停下，稍后再喂一个值继续」。

### 7.1 三层分别做什么？

```text
┌─────────────────────────────────────────┐
│  Coro API：yield / start / resume / …   │  给用户用的挂起与驱动
├─────────────────────────────────────────┤
│  Answer：Done | Yielded | Stopped | Failed │  作为 Cont 的「最终答案」类型 r
├─────────────────────────────────────────┤
│  Cont：unit / bind / runCont             │  纯续延传递，尚无「暂停」语义
└─────────────────────────────────────────┘
```

1. **Cont 层**：只会一路算到调用顶层 `k` 为止，本身不「暂停」。
2. **Answer 层**：把 `r` 从「普通值」换成可观察的状态：
   - `Done { tag="done", value }` — 整段结束；
   - `Yielded { tag="yielded", value, cont }` — 刚挂起；`cont` 是恢复后续延；
   - `Stopped { tag="stopped", reason? }` — 主动停止 / 取消（不调用续延）；
   - `Failed { tag="failed", error }` — 管道级失败（不调用续延）。
3. **Coro API**：用 Cont 编出 Yielded / Stopped / Failed，并用驱动函数推进。

### 7.2 yield：故意不调用当前续延

```lua
yield(v) = Cont.wrap(function(k)
  return Yielded(v, k)   -- 把 k 存起来，先返回给外面
end)
```

关键点：这里 **没有** `return k(something)`。计算在 Cont 意义下「结束」了，但结束时带出的答案是 `Yielded`，外面还能拿到当时的 `k`。

教学一句话：**yield = 捕获当前续延并交给调度者**。

### 7.3 start：顶层续延负责打成 Done

```lua
start(ma) = runCont(ma, function(a)
  return Done(a)
end)
```

若 `ma` 从不 `yield`，会直接得到 `Done(最终值)`。若中途 `yield`，则 `runCont` 的结果是某个 `Yielded`，顶层的 `Done` 包装还轮不到执行。

### 7.4 resume：把值喂回保存的续延

```lua
resume(y, b) = y.cont(b)
```

`y.cont` 正是 yield 时的 `k`。喂入 `b` 后，从断点继续；下一次可能再 Yielded，或走到顶层 `Done`。

### 7.5 一次完整的逐步轨迹

```lua
local body =
  Coro.yield("ping") >> function(reply)
    return Cont.unit("got:" .. tostring(reply))
  end

local a1 = Coro.start(body)
-- a1.tag == "yielded", a1.value == "ping"
-- a1.cont 是「收到 reply 之后」的剩余计算

local a2 = Coro.resume(a1, "pong")
-- a2.tag == "done", a2.value == "got:pong"
```

过程直觉：

```text
start(body)
  → body( λfinal. Done(final) )
  → 跑到 yield("ping")：返回 Yielded("ping", k_rest)
     其中 k_rest ≈ λreply. 后续 bind … 最终 Done(...)

resume(a1, "pong")
  → k_rest("pong")
  → Cont.unit("got:pong")(λfinal. Done(final))
  → Done("got:pong")
```

### 7.6 驱动助手

| API | 作用 |
|-----|------|
| `step(answer, v)` | Done/Stopped/Failed 则不动；Yielded 则 `resume` |
| `run(ma, handler)` | 循环至终态：Done → 最终值；Stopped/Failed → `nil, answer` |
| `runEx(ma, handler)` | → `"done"\| "stopped"\| "failed"`, payload |
| `collect(ma)` | 记录所有 yield 载荷；每次以 `true` resume；中止时第三返回值为 answer |
| `stop(reason?)` / `fail(err)` | 与 `yield` 同形：不调用 `k`，直接返回终态 Answer |

生成器与交互式问答见 `examples/coro_generator.lua`、`examples/coro_interactive.lua`。  
停止 / 失败 / 取消见 `examples/fx_stop_cancel.lua`、`examples/fx_fail_catch.lua`。

### 7.7 停止、失败与 Cont 层异常

两层不要混用：

| 层 | API | 用途 |
|----|-----|------|
| Coro / fx | `Coro.stop` / `Coro.fail`、`fx.stop` / `fx.fail`、`opts.cancel` | 管道驱动中止；`fx.run` 返回结构化结果表 |
| Cont | `Cont.throw` / `Cont.catch` / `Cont.protect` | `evalCont` 路径上的显式异常（handler 栈，不用 Lua error 传业务失败） |

`stop`/`fail` 与 `yield` 一样**故意不调用当前续延**，因此 `start`/`run` 直接看到 `Stopped`/`Failed`，不会再包成 `Done`。  
`Cont.throw` 则调用 catch 栈顶的逃逸续延（实现上可配合 `pcall` 兜住真正的 Lua error）。示例：`examples/cont_catch_throw.lua`。

---

## 8. 和 Lua 原生 coroutine 的对比

| | 本库 CPS 协程 | `coroutine.yield` / `resume` |
|--|--------------|------------------------------|
| 状态保存在 | 显式函数闭包（续延） | 解释器协程栈 |
| 与 Monad | 同一套 `>>` / Cont | 独立机制 |
| 多路调度 | 本库刻意只做单路 | 可自建调度器 |
| 调试 | 可打印 Yielded.cont 的来源逻辑 | 需调试器看栈 |
| 性能 | 教学优先，函数嵌套有开销 | 通常更轻 |

本库 **刻意不** 封装原生 coroutine，避免两套「暂停」语义缠在一起。

---

## 9. 设计取舍与非目标

**取舍**

- 用 `Done|Yielded|Stopped|Failed` 作 Cont 的答案类型，而不是另起一套解释器——这样 `bind` 仍然是原来的 Cont bind，协程只是换了 `r`。
- `yield` 返回的 Cont 与普通 Cont 相同，故可与 `>>`、`@mdo` 混用。
- `shift`/`reset` 提供定界教学模型；与 `callCC` 并存，职责分开。

**非目标**

- 多协程就绪队列 / 抢占；
- ContT 变换器栈（MaybeT Cont 等）；
- 与原生 coroutine 的双向桥接。

---

## 10. 阅读与实验路径

1. 读本节 §2–§3，跑 `examples/cont_cps_basics.lua`。
2. 读 §4，跑 `examples/cont_callcc.lua`。
3. 读 §5–§6，对照 `cont_cps_basics.lua` 末尾的 mapCont / withCont / shift。
4. 读 §7，跑 `examples/coro_generator.lua` 与 `coro_interactive.lua`。
5. 读停止/异常：`examples/cont_catch_throw.lua`、`fx_stop_cancel.lua`；异步效果：[异步效果同步写法.md](./异步效果同步写法.md)。
6. API 速查：`docs/API.md` 中 Cont / Coro / fx 三节；总架构：`docs/设计说明.md`。

若只记三句话：

1. **Cont** 把「剩下怎么做」变成参数 `k`；  
2. **bind** 负责把外层的 `k` 传到链条末端；  
3. **yield** 通过「先不调用 `k`、把 `k` 装进 Yielded」实现挂起，**resume** 再调用它。
