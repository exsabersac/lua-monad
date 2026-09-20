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
| 顺序 | 按**首次出现**的名字顺序 `foldl (>>) Cont.unit` |
| 同名再定义 | **原地替换**该名对应步骤，不改变相对次序 |
| 非函数赋值 | 普通字段，**不进**管道（数字/表等辅助数据 ok） |
| 助手函数 | 请写在某步内部的 `local function`；挂到 env 的函数一律当步骤 |
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

注意分层（outer → inner），避免 A 调 B、B 再调 A 造成无限递归。助手函数务必写在步内 `local`，不要挂到 env。

