# Cont 环境组合（`withEnv`）

面向 **Cont only** 的轻量「步骤环境」：在 `withEnv(body)` 里往 env 上定义函数，**默认**按定义顺序自动 `>>` 折成一条管道。无 `ContPipe()`、无 opt-in 开关；不依赖 PLoop；本特性**不使用** Lua 原生 `coroutine` / 已放弃的 `runDo`/`perform` 方案。

实现：[`src/cont_env.lua`](../src/cont_env.lua)。入口：`cont_env.withEnv` / `Cont.withEnv`（`require("cont")` 后首次调用会延迟加载；或先 `require("cont_env")`）。

## 快速示例

```lua
package.path = "src/?.lua;" .. package.path
local Cont = require("cont")

local pipe = Cont.withEnv(function(_ENV)
  function add1(x)
    return Cont.unit(x + 1)
  end
  function times2(x)
    return Cont.unit(x * 2)
  end
end)

assert(Cont.evalCont(pipe(3)) == 8)  -- (3+1)*2
```

可执行示例：[`examples/cont_env_pipe.lua`](../examples/cont_env_pipe.lua)。

## 语义

| 规则 | 说明 |
|------|------|
| 默认收集 | env 上每次**函数**写入都记为步骤；无 ContPipe / 无标志位 |
| 顺序 | 默认按**首次出现**名顺序；可用 `__AfterStep__` / `__BeforeStep__` 拓扑重排（见下） |
| 同名再定义 | **原地替换**该名对应步骤，不改变相对次序 |
| 非函数赋值 | 普通字段，**不进**管道（数字/表等辅助数据 ok） |
| 助手函数 | 步内 `local function`；或 `__Helper__()` / `__NotStep__()` 后再赋函数（存 env 不进管道）；未标注则挂到 env 的函数一律当步骤 |
| 零步骤 | 返回恒等管道，等价于 `Cont.unit` |
| 返回值 | `composed(x) → Cont`；另在 env 上 `rawset` `pipe` / `compose` 指向同一函数（body 返回后可读） |

等价展开：

```lua
composed(x) = Cont.unit(x) >> step1 >> step2 >> ... >> stepN
```

## 与 `@mdo`、与已放弃的 native `runDo` 对比

| 方案 | 形态 | 范围 | 说明 |
|------|------|------|------|
| **`Cont.withEnv`** | 运行时 env + `__newindex` | **仅 Cont** | 步骤是 `a → Cont r b`，默认自动 `>>`；适合 CPS 管道拼装 |
| **`@mdo` … `@end`** | 源码预处理 | **任意** 带 `>>`/`..` 的 monad | 类 Haskell `<-` 绑定；生成嵌套 `function`；见 [do语法.md](./do语法.md) |
| **native `runDo` / `perform`（已放弃）** | Lua 协程在 do 块里 `perform` | 曾设想通用 | 依赖 `coroutine`，与本库「Cont 教学 CPS」主线不一致；本分支**不包含** |

选用建议：

- 要在 **Cont** 里按名字组织一串 CPS 步骤 → `withEnv`。
- 要可读的 `x <- ma` 且跨 Maybe/List/… → `@mdo`。
- 不要把「环境收集」与「do 语法糖」混成一条 API。

## API

```text
cont_env.withEnv(body) → composed
Cont.withEnv(body)     → composed   -- 同实现
```

- `body(env)`：用户把步骤写到 `env`（参数名常取 `_ENV`，以便 `function name` 语法写入 env）。
- `composed`：`function(x) … end`，返回 Cont 值；用 `Cont.evalCont` / `runCont` 取答案。

## 注意

- 重新赋值**非函数**到曾用过的步骤名时，该名会从管道中移除（其余步骤相对顺序不变）。
- `env.pipe` / `env.compose` 在 `body` **返回之后**才挂上；body 内读不到最终组合函数，请用 `withEnv` 的返回值。

## 更复杂的例子

基础管道见上文与 [`examples/cont_env_pipe.lua`](../examples/cont_env_pipe.lua)。下面几个示例把 `withEnv` 与 callCC、CPS 协程、配置字段、较长算术链组合起来（均在仓库根目录 `lua examples/...` 可跑）：

| 文件 | 在演示什么 |
|------|------------|
| [`examples/cont_env_callcc.lua`](../examples/cont_env_callcc.lua) | `validate → transform → finalize`；`Cont.callCC` / `escape` 拒绝负数时整链中止；对照 `evalCont` 成功与 abort |
| [`examples/cont_env_coro_mix.lua`](../examples/cont_env_coro_mix.lua) | 中间步 `Coro.yield("need-input") >> …`；用 `Coro.start`/`resume` 或 `Coro.run` 驱动。**注意**：`Coro.yield` ≠ Lua 原生 `coroutine`；`withEnv` 只组织 `>>` |
| [`examples/cont_env_data_driven.lua`](../examples/cont_env_data_driven.lua) | env 上非函数字段（`threshold` / `label`）不进管道；步骤闭包读 `env.threshold` 做 clamp + tag |
| [`examples/cont_env_fact_pipeline.lua`](../examples/cont_env_fact_pipeline.lua) | 较长 CPS 链（normalize → square → sum）与阶乘步骤；以及对整段结果 `mapCont` |

配置字段写法提示（两种均可；**勿**在参数名不是 `_ENV` 时写 `function clamp`——那会落到 chunk 全局、管道为空）：

```lua
-- A) 参数名 _ENV：`function clamp` 写入收集表；字段经 _ENV 读写
Cont.withEnv(function(_ENV)
  threshold = 10
  function clamp(x)
    local t = threshold
    if x > t then return Cont.unit(t) else return Cont.unit(x) end
  end
  function tag(x)
    return Cont.unit({ n = x, label = label })
  end
  label = "score"  -- 步骤在 pipe(x) 时读取即可
end)

-- B) 参数名 env：用赋值注册步骤，闭包捕获 env
Cont.withEnv(function(env)
  env.threshold = 10
  env.label = "score"
  env.clamp = function(x)
    local t = env.threshold
    if x > t then return Cont.unit(t) else return Cont.unit(x) end
  end
  env.tag = function(x)
    return Cont.unit({ n = x, label = env.label })
  end
end)
```

body 内若需要 `type` / `print` / `math`，且参数名为 `_ENV`，请先在 chunk 顶层 `local type, print, math = type, print, math`，否则自由名会查 env 表而非全局。

## 多管道互调与局部函数

`withEnv` 的返回值本身就是 `a → Cont r b`，因此多条管道可以互相调用，也可以把整条管道当作另一步：

| 文件 | 在演示什么 |
|------|------------|
| [`examples/cont_env_mutual_pipes.lua`](../examples/cont_env_mutual_pipes.lua) | 多条独立管道（`prep` / `core` / `format`）分层互调：步内 `return prep(x) >> …`，或 `return core(x)`；另含非 withEnv 的小 Cont 助手 |
| [`examples/cont_env_local_helpers.lua`](../examples/cont_env_local_helpers.lua) | **正确**：步内 `local function` 助手 + env 非函数配置；**错误对照**：把 helper `function` 到 env 会多出一个管道步骤 |
| [`examples/cont_env_pipe_as_step.lua`](../examples/cont_env_pipe_as_step.lua) | 整段 `inner = Cont.withEnv(...)` 作为 `outer` 的 `mid` 步：`function mid(x) return inner(x) end`——干净的「CPS 调 CPS」 |

组合直觉：

```lua
-- 管道只是函数；用 >> 或嵌套调用即可
local prep = Cont.withEnv(function(_ENV) ... end)
local core = Cont.withEnv(function(_ENV)
  function ingest(x)
    return prep(x) >> function(y) return Cont.unit(y) end
  end
  ...
end)

-- 或：整条 inner 当 outer 的一步
local inner = Cont.withEnv(...)
local outer = Cont.withEnv(function(_ENV)
  function mid(x) return inner(x) end
end)
```

注意分层（outer → inner），避免 A 调 B、B 再调 A 造成无限递归。助手可用步内 `local`，或 `__Helper__()` / `__NotStep__()` 标注后再挂到 env。


## 属性系统（PLoop 风格轻量版）

不依赖 PLoop。在 `withEnv(body)` 内调用 `__Name__()` **排队**一个属性；**紧接着**赋给 env 的下一个函数即目标（与 PLoop 属性语法同构的运行时版）。

### 内置属性

| 属性 | 作用 |
|------|------|
| `__Helper__()` / `__NotStep__()` | 函数存到 env，**不**加入 `>>` 管道顺序（解决「助手挂在 env 上」） |
| `__Wrap__(wrapper)` | `wrapper(step) → new_step`；注册时包装 |
| `__Before__(pre)` | **Cont 包装**糖：`λx. pre(x) >> step`（改步骤本身，不改管道位置） |
| `__After__(post)` | **Cont 包装**糖：`λx. step(x) >> post`（改步骤本身，不改管道位置） |
| `__AfterStep__(name)` | **管道顺序**：把下一步 `F` 排到步骤 `name` **之后**（拓扑边 `name → F`） |
| `__BeforeStep__(name)` | **管道顺序**：把下一步 `F` 排到步骤 `name` **之前**（拓扑边 `F → name`） |
| `__Until__(pred[, max])` | 每步结果 `a` 若 `pred(a)` 则停，否则把 `a` 再喂给 step；默认 `max=1000` 防死循环 |
| `__Timeout__(secs[, on_timeout])` | **合作式**超时：`t0=os.clock()`，`step(x) >>` 得 `a` 后若 `elapsed>secs`，则 `on_timeout(a, elapsed)` 或默认 `Cont.unit({tag="timeout", value=a, elapsed})`。**不能**打断同步步中途 |
| `__Retry__(n, pred)` | `pred(a)` 表示需要重试；始终用**原始** `x` 再跑 `step`，最多 `n` 次；若最后一次仍 `pred` 则返回该 `a` |
| `__Require__(pred[, on_fail])` | 步前：若 `not pred(x)`，返回 `on_fail(x)` 或默认 `Cont.unit({tag="rejected", value=x})`；否则 `step(x)` |
| `__Trace__([label])` | 步前/步后 `print`，不改变值；`label` 可选（默认 `"trace"`） |
| `__Catch__(handler)` | `Cont.catch(step(x), handler)`；步内 `Cont.throw` / Lua error |

多个属性可叠在同一函数前：按**排队顺序**依次把包装器折到目标上。例如：

```lua
__Before__(pre)
__After__(post)
function step(x) ... end
-- 等价于 λx. (pre(x) >> step) >> post，即 pre → step → post
```

`callCC`：请在步骤体内直接用 `Cont.callCC`（见 `examples/cont_env_callcc.lua`）；本 MVP 不另做 `__CallCC__` 包装。

### `__Before__`/`__After__`（Cont 包装）vs `__BeforeStep__`/`__AfterStep__`（管道顺序）

| | Cont 包装 | 管道顺序 |
|--|-----------|----------|
| 属性 | `__Before__(pre)` / `__After__(post)` | `__BeforeStep__(name)` / `__AfterStep__(name)` |
| 作用 | 把 `pre`/`post` **串进该步骤的 Cont** | 改变步骤在 `>>` 链中的**相对位置** |
| 不改什么 | 不改步骤在管道中的名次序 | 不改步骤函数体（除非同时叠了包装属性） |

无 `AfterStep`/`BeforeStep` 时，仍按定义序（首次出现名）折叠。有约束时：以定义序为节点，把约束当有向边，**Kahn 拓扑排序**；平局按定义序；环或缺目标（含指向 Helper/未注册名）→ 报错。同名重定义会**更新**该名上的顺序约束。

```lua
-- 源码里先写 later，再用 AfterStep 排到 early 之后 → early >> later
local pipe = Cont.withEnv(function(_ENV)
  __AfterStep__("early")
  function later(x) return Cont.unit(x * 10) end
  function early(x) return Cont.unit(x + 1) end
end)
assert(Cont.evalCont(pipe(2)) == 30)  -- (2+1)*10
```

### 用法示例

```lua
local pipe = Cont.withEnv(function(_ENV)
  __Helper__()
  function bump(x)
    return Cont.unit(x + 1)
  end

  __Before__(function(x)
    print("in", x)
    return Cont.unit(x)
  end)
  __After__(function(x)
    print("out", x)
    return Cont.unit(x)
  end)
  function work(x)
    return bump(x) >> function(y) return Cont.unit(y * 2) end
  end

  __Until__(function(a) return a >= 10 end)
  function grow(x)
    return Cont.unit(x + 3)
  end
end)
```

可执行示例：

| 文件 | 演示 |
|------|------|
| [`examples/cont_env_attrs_helper.lua`](../examples/cont_env_attrs_helper.lua) | `__Helper__` vs 误把助手当步骤 |
| [`examples/cont_env_attrs_until.lua`](../examples/cont_env_attrs_until.lua) | `__Until__` 增长到 ≥ 10 |
| [`examples/cont_env_attrs_before_after.lua`](../examples/cont_env_attrs_before_after.lua) | `__Before__` / `__After__` Cont 包装日志与 `cont_env.attrs` |
| [`examples/cont_env_attrs_after_step.lua`](../examples/cont_env_attrs_after_step.lua) | `__AfterStep__` / `__BeforeStep__` 管道重排（对比 Cont 包装） |
| [`examples/cont_env_attrs_timeout.lua`](../examples/cont_env_attrs_timeout.lua) | `__Timeout__` 合作式超时（含自定义 `on_timeout`） |
| [`examples/cont_env_attrs_retry.lua`](../examples/cont_env_attrs_retry.lua) | `__Retry__` 用原输入重试 |
| [`examples/cont_env_attrs_require_trace.lua`](../examples/cont_env_attrs_require_trace.lua) | `__Require__` + `__Trace__` |

### Timeout / Retry / Require / Trace 速览

```lua
__Timeout__(0.05)                    -- 步后检查；超时默认 {tag="timeout",...}
__Timeout__(0.05, function(a, e)     -- 或自定义 Cont
  return Cont.unit({ slow = true, a = a, e = e })
end)

__Retry__(3, function(a) return a < 0 end)  -- pred 真则用原 x 再试

__Require__(function(x) return x ~= nil end)
__Require__(ok_pred, function(x) return Cont.unit({tag="bad", x=x}) end)

__Trace__("step-name")               -- print [step-name] before/after
__Catch__(function(err) return Cont.unit({recovered=err}) end)
```

注意：`__Timeout__` **不是**抢占式；长同步循环跑完才会看到超时。

### 规则与错误

- 属性必须紧跟**函数**赋值；若随后赋非函数，或 body 结束时仍有未消耗属性 → **报错**。
- 不可覆盖 `__Helper__` 等属性构造器名。
- 同名先做步骤再 `__Helper__` 重定义 → 从管道移除，仍可在 env 上读到函数。
- `__AfterStep__` / `__BeforeStep__`：目标名须为**管道步骤**（非 Helper）；环或缺目标 → 报错；同名重定义更新约束。
- 独立（非 env）：`cont_env.attrs.__Before__(pre)(step)` 等包装；`attrs.__AfterStep__(name)` / `__BeforeStep__(name)` 返回描述符（顺序约束仅在 `withEnv` 内生效），见 `src/cont_env.lua`。


## 异步效果的同步写法（`fx`）

若要在 `withEnv` 管道里写「看起来同步」的 wait / 连接 / 点击，请用教学层 [`src/fx.lua`](../src/fx.lua)：效果经 `Coro.yield` 交出，由 `fx.run` 的 handlers 兑现。详见 **[异步效果同步写法.md](./异步效果同步写法.md)**。

示例：`examples/fx_wait_click_flow.lua`、`fx_custom_handlers.lua`、`fx_with_attrs.lua`。
