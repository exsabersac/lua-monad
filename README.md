# Lua Monad · CPS 续延

本仓库用纯 Lua 模拟 Haskell 风格的 Monad，**主线是 Cont（续延）与 CPS**：

- 用 `Cont` 显式传递「算完之后做什么」；
- 用 `Coro` 把挂起编成 `Done | Yielded`（**不是** Lua 原生 `coroutine` 当业务语义）；
- 用 `Cont.withEnv` 把一串 CPS 步进函数自动 `>>` 成管道，并可挂 PLoop 风格属性；
- 用 `fx` 做「同步写法、异步效果」：等待 / 联网 / 点击经 `Coro.yield` 交给驱动器。

其它实例（Maybe、List、State…）仍保留，作对照与练手，见文末。

**深入阅读（建议按此顺序）：**

1. [CPS 设计与工作原理](docs/CPS设计与原理.md) — Cont、callCC、定界续延、协程三层模型  
2. [Cont 环境组合](docs/Cont环境组合.md) — `withEnv`、属性、`AfterStep`  
3. [异步效果同步写法](docs/异步效果同步写法.md) — `fx.wait` / `connect` / `click`  
4. [设计说明](docs/设计说明.md) · [API 参考](docs/API.md)

需要 **Lua 5.4+**；在仓库根目录执行示例（脚本已设置 `package.path`）。

---

## 1. Cont：续延 monad

```text
Cont r a  ≈  (a → r) → r
```

```lua
local Cont = require("cont")

-- unit / bind（也可用 >>）
local m = Cont.unit(2) >> function(x)
  return Cont.unit(x + 3)
end
assert(Cont.evalCont(m) == 5)

-- callCC：提前跳出
local v = Cont.evalCont(Cont.callCC(function(escape)
  return Cont.unit(1) >> function(_)
    return escape(42) >> function(_)
      return Cont.unit(999)  -- 不会成为结果
    end
  end
end))
assert(v == 42)
```

常用 API：`runCont` / `evalCont`、`mapCont` / `withCont`、`callCC`、`reset` / `shift`。  
符号糖：`ma >> f`（bind）、`ma .. mb`（丢弃左结果）。详见 [CPS 设计与原理](docs/CPS设计与原理.md)。

示例：`examples/cont_cps_basics.lua`、`examples/cont_callcc.lua`。

---

## 2. Coro：CPS 协程（Cont 上的挂起）

答案类型：

| 标签 | 形状 | 含义 |
|------|------|------|
| `Done` | `{ tag="done", value }` | 算完 |
| `Yielded` | `{ tag="yielded", value, cont }` | 挂起；`cont` 是恢复后续延 |

```lua
local Cont = require("cont")
local Coro = require("coro")

local body = Coro.yield("ping") >> function(reply)
  return Cont.unit("got:" .. tostring(reply))
end

local a1 = Coro.start(body)           -- Yielded "ping"
local a2 = Coro.resume(a1, "pong")    -- Done "got:pong"
```

驱动助手：`step` / `run` / `collect`。  
要点：**yield = 捕获当前续延**，与原生 `coroutine.yield` 不是同一套业务 API。

示例：`examples/coro_generator.lua`、`examples/coro_interactive.lua`。

---

## 3. Cont.withEnv：组织 CPS 函数组合

进入环境后，**默认**把写入的函数按序（或按 `AfterStep` 约束）折成：

```text
composed(x) = Cont.unit(x) >> step1 >> step2 >> …
```

无需 `ContPipe()`。

```lua
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

### 属性（先登记，再定义函数）

| 属性 | 作用 |
|------|------|
| `__Helper__` / `__NotStep__` | 挂在 env 上，**不进**管道 |
| `__Before__` / `__After__` | 一步内外的 Cont 包装（不是排步序） |
| `__Wrap__` / `__Until__` / `__Timeout__` / `__Retry__` / `__Require__` / `__Trace__` | 包装、循环、协作式超时、重试、守卫、跟踪 |
| `__AfterStep__("name")` / `__BeforeStep__("name")` | **步与步**的相对顺序（拓扑排序） |

完整说明：[Cont 环境组合](docs/Cont环境组合.md)。

**基础 / 组合：**  
`cont_env_pipe.lua` · `cont_env_mutual_pipes.lua` · `cont_env_local_helpers.lua` · `cont_env_pipe_as_step.lua` · `cont_env_callcc.lua` · `cont_env_coro_mix.lua` · `cont_env_data_driven.lua` · `cont_env_fact_pipeline.lua`

**属性：**  
`cont_env_attrs_helper.lua` · `cont_env_attrs_until.lua` · `cont_env_attrs_before_after.lua` · `cont_env_attrs_after_step.lua` · `cont_env_attrs_timeout.lua` · `cont_env_attrs_retry.lua` · `cont_env_attrs_require_trace.lua`

---

## 4. fx：同步写法 · 异步效果

业务管道仍用 `withEnv`；`fx.wait` / `fx.connect` / `fx.click` 内部 `Coro.yield` 出请求，由 `fx.run`（或自定义 handlers）兑现。默认是**模拟**等待 / 网络 / 点击，便于练模式。

```lua
local Cont = require("cont")
local fx = require("fx")

local flow = Cont.withEnv(function(_ENV)
  function pause(_)
    return fx.wait(0.05)
  end
  function login(_)
    return fx.click("login")
  end
  function api(_)
    return fx.connect("api.example")
  end
end)

local result = fx.run(flow(true))
```

文档：[异步效果同步写法](docs/异步效果同步写法.md)。  
示例：`fx_wait_click_flow.lua` · `fx_custom_handlers.lua` · `fx_with_attrs.lua`。

---

## 5. 如何跑 CPS 相关示例

```bash
cd /path/to/lua-monad

lua tests/run.lua

# Cont 基础
lua examples/cont_cps_basics.lua
lua examples/cont_callcc.lua

# CPS 协程
lua examples/coro_generator.lua
lua examples/coro_interactive.lua

# withEnv 管道
lua examples/cont_env_pipe.lua
lua examples/cont_env_attrs_after_step.lua
lua examples/cont_env_coro_mix.lua

# 异步效果
lua examples/fx_wait_click_flow.lua
lua examples/fx_custom_handlers.lua
```

---

## 6. 其它 Monad（对照用）

共用 `makeMonad` + 元表糖（`>>` / `..` / `M(x)`）。实例包括：

| 模块 | 用途 |
|------|------|
| Maybe | 可失败；LYAH 走钢丝见 `examples/walk_the_line.lua` |
| List | 非确定性 |
| State / Reader / Writer / RWS | 状态、环境、日志及组合 |
| Status | Ok/Err（≈ Either） |
| Identity | 平凡包装 |

`@mdo` 预处理可把类 Haskell do 写成 `.mdo` 再执行，见 [do 语法](docs/do语法.md)：

```bash
lua tools/mdo.lua --run examples/do_maybe_foo.mdo
```

通用演示：`lua examples/demo.lua`。

---

## 目录（CPS 相关优先）

```
lua-monad/
  src/cont.lua          # Cont：unit/bind/callCC/mapCont/shift…
  src/cont_env.lua      # withEnv + 属性 + AfterStep
  src/coro.lua          # CPS 协程 Done|Yielded
  src/fx.lua            # wait/connect/click + fx.run
  src/monad.lua         # makeMonad + 元表糖
  src/{maybe,list,state,status,identity,reader,writer,rws,mdo}.lua
  docs/CPS设计与原理.md
  docs/Cont环境组合.md
  docs/异步效果同步写法.md
  docs/{设计说明,API,do语法}.md
  examples/cont_*.lua / coro_*.lua / fx_*.lua / …
  tests/run.lua
  tools/mdo.lua
```

---

## 许可

教学示例，随意使用。
