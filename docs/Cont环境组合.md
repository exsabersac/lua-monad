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
