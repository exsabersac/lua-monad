# Lua Monad · CPS 续延

**版本 `0.2.19-eng`**（`fx_sched` drive kind 表拆分；工程可用：… / wait_until / wait_real(opt-in) / chan / supervise / **lane 命名子流** / **proxy（tabProxy 轻量）** / Unity Bootstrap / abort·iquit·seq·suspend / Cont 热路径 / sync fast-path·**bench/compare/summary/alloc/doctor/trace/profile·scenarios·ci_tools**；对照 [tabMachine对照](docs/tabMachine对照.md) / [性能与工具](docs/性能与工具.md)；路线收口见 [版本与路线](docs/版本与路线.md)；见 [CHANGELOG](CHANGELOG.md) / [工程可用验收](docs/工程可用验收.md)）。

本仓库用纯 Lua 模拟 Haskell 风格的 Monad，**主线是 Cont（续延）与 CPS**：

- 用 `Cont` 显式传递「算完之后做什么」；
- 用 `Coro` 把挂起/中止编成 `Done | Yielded | Stopped | Failed`（**不是** Lua 原生 `coroutine` 当业务语义）；
- 用 `Cont.withEnv` 把一串步进（普通 `a→b` 或 `a→Cont`）自动 `>>` 成管道，并可挂 PLoop 风格属性（含 `init`/`finally` 生命周期）；
- 用 `fx` 做「同步写法、异步效果」：等待 / 联网 / 点击经 `Coro.yield` 交给驱动器。

其它实例（Maybe、List、State…）仍保留，作对照与练手，见文末。

**深入阅读（建议按此顺序）：**

1. [CPS 设计与工作原理](docs/CPS设计与原理.md) — Cont、callCC、定界续延、协程三层模型  
2. [Cont 环境组合](docs/Cont环境组合.md) — `withEnv`、属性、`AfterStep`  
3. [异步效果同步写法](docs/异步效果同步写法.md) — `fx.wait` / `connect` / `click`；**并行** `when_all`/`when_any`；**Fork/Join** `fork`/`join`  
4. [tabMachine 对照](docs/tabMachine对照.md) — abort/stop、iquit、seq、suspend 映射  
5. [工程对接与后续](docs/工程对接与后续.md) — 游戏时间 Scheduler、**GameSim**、**地牢突袭**、P0–P2；[工程可用验收](docs/工程可用验收.md)  
6. [Unity 对接](docs/Unity对接.md) — Unity + Lua 5.3（xLua/tolua/slua）、scaled 游戏时间、主线程桥接、[`host/unity/`](host/unity/) 模板  
7. [Lua 5.3 兼容性](docs/Lua53兼容性.md) — `__shr`、避免 5.4-only、`lua5.3 tests/run.lua`  
8. [性能与工具](docs/性能与工具.md) — Cont 热路径、bench / flow_doctor / trace / profile；一页速查 [工具速查](docs/工具速查.md)；收口 [工具套件收口](docs/工具套件收口.md)；[`tools/README.md`](tools/README.md)  
9. [设计说明](docs/设计说明.md) · [API 参考](docs/API.md) · [核心整理说明](docs/核心整理说明.md)（0.2.19 drive kind 表）

需要 **Lua 5.3+**（Unity / xLua / tolua / slua 多为 5.3；已在 5.3.6 验证）。在仓库根目录执行示例（脚本已设置 `package.path`）：

```bash
./scripts/test_lua53.sh
# 或
lua5.3 tests/run.lua
# 或
lua tests/run.lua   # 若 lua 已是 5.3+
```

**周边工具**（仓库根目录）：

```bash
./scripts/ci_tools.sh                     # 测试 + doctor + bench --ci + alloc + profile smoke
# ALLOW_BENCH_REGRESSION=1 ./scripts/ci_tools.sh   # bench 回归 soft-fail
# PROFILE=1 ./scripts/ci_tools.sh                 # profile_flow N=20
lua5.3 tools/bench_cont_fx.lua --alloc    # 热路径粗测（--json / --filter / --alloc）
lua5.3 tools/bench_compare.lua --ci       # 对照 baseline；--write-baseline 更新
lua5.3 tools/bench_summary.lua --out tools/bench_summary.md   # JSON → Markdown 表
lua5.3 tools/profile_flow.lua --smoke     # Cont/fx 场景 tracer 打点（scenarios；--json）
lua5.3 tools/alloc_hotspot.lua            # Cont >> 分配热点
lua5.3 tools/flow_doctor.lua --ci         # 常见误配置检查（CI）
lua5.3 tools/trace_dump.lua --lane --chan # trace 事件 dump（stdout）
lua5.3 tools/trace_export.lua --lane --chan   # trace 事件导出 JSON（默认 tools/trace_out.json）
```

一页 copy-paste 命令：[工具速查](docs/工具速查.md)。共享场景：[`tools/scenarios/`](tools/scenarios/)。  
详见 [性能与工具](docs/性能与工具.md) / [`tools/README.md`](tools/README.md)。


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

无需 `ContPipe()`。步骤可写普通 `a → b`（非 Cont 返回值自动 `Cont.unit`）；已返回 Cont 的则原样。

```lua
local Cont = require("cont")

local pipe = Cont.withEnv(function(_ENV)
  function add1(x)
    return x + 1              -- 普通值 → 自动提升
  end
  function times2(x)
    return Cont.unit(x * 2)   -- 已是 Cont
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
`cont_env_pipe.lua` · `cont_env_plain_steps.lua` · `cont_env_mutual_pipes.lua` · `cont_env_local_helpers.lua` · `cont_env_pipe_as_step.lua` · `cont_env_callcc.lua` · `cont_env_coro_mix.lua` · `cont_env_data_driven.lua` · `cont_env_fact_pipeline.lua`

**属性：**  
`cont_env_attrs_helper.lua` · `cont_env_attrs_until.lua` · `cont_env_attrs_before_after.lua` · `cont_env_attrs_after_step.lua` · `cont_env_attrs_timeout.lua` · `cont_env_attrs_retry.lua` · `cont_env_attrs_require_trace.lua` · `cont_env_finally.lua`

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
assert(result.ok)
local value = result.value  -- fx.run 返回结构化结果表
```

亦支持 `fx.stop` / `fx.fail`、`opts.cancel` 取消令牌，以及 Cont 层 `Cont.throw`/`Cont.catch`。

**并行（对齐 C# `Task.WhenAll` / `WhenAny`）**：`fx.when_all` / `fx.when_any`（Cont 组合子）与 `fx.run_all` / `fx.run_any`（顶层驱动）。  
**Fork/Join（对齐 `Task.Run` + `await`）**：`fx.fork` / `fx.join` / `fx.join_handles` — 非结构化：早启动、中间可做别的事、稍后再汇合。  
**有限并发**：`fx.map_parallel(items, worker, {concurrency=N})` — 滑动窗口池，结果按输入顺序。  
**超时**：`fx.with_timeout(ma, seconds)` — 竞速 deadline；超时 → `Failed("timeout")`；**fork 子任务继承剩余截止**（`opts.timeout`/`deadline` 同理）。  
**取消传播**：session `opts.cancel` 停未完成子任务；`join(..., {cancel_siblings=true})` 取消同父兄弟。  
wait / fork 子任务由 [`src/fx_sched.lua`](src/fx_sched.lua) nursery + 时间轮并发。C# 对照表见 [异步效果同步写法](docs/异步效果同步写法.md)。

文档：[异步效果同步写法](docs/异步效果同步写法.md)。  
示例：`fx_wait_click_flow.lua` · `fx_custom_handlers.lua` · `fx_with_attrs.lua` · `fx_stop_cancel.lua` · `fx_fail_catch.lua` · `fx_when_all.lua` · `fx_when_any.lua` · `fx_parallel_pipeline.lua` · `fx_fork_join.lua` · `fx_map_parallel.lua` · `fx_with_timeout.lua` · `fx_cancel_tree.lua` · `cont_catch_throw.lua`。

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
lua examples/cont_env_finally.lua
lua examples/cont_env_coro_mix.lua

# 异步效果 / 停止与异常 / 并行 WhenAll·WhenAny / Fork·Join
lua examples/fx_wait_click_flow.lua
lua examples/fx_custom_handlers.lua
lua examples/fx_stop_cancel.lua
lua examples/fx_fail_catch.lua
lua examples/fx_when_all.lua
lua examples/fx_when_any.lua
lua examples/fx_parallel_pipeline.lua
lua examples/fx_fork_join.lua
lua examples/fx_map_parallel.lua
lua examples/fx_with_timeout.lua

# 综合演示
lua examples/dungeon_raid/main.lua
lua examples/escort_mission/main.lua
lua examples/worker_pool/main.lua
lua examples/fx_cancel_tree.lua
lua examples/cont_catch_throw.lua

# Unity 适配形状（无编辑器）：Mock host
lua5.3 -e 'package.path="src/?.lua;host/unity/?.lua;"..package.path; require("MockUnityHost").demo()'
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
  src/coro.lua          # CPS 协程 Done|Yielded|Stopped|Failed
  src/fx.lua            # wait/connect/click/stop/fail/when_all|any/fork|join + fx.run
  src/fx_sched*.lua     # nursery session + 时间轮；drive 按 kind 分模块（见 docs/核心整理说明.md）
  src/monad.lua         # makeMonad + 元表糖
  src/{maybe,list,state,status,identity,reader,writer,rws,mdo}.lua
  docs/CPS设计与原理.md
  docs/Cont环境组合.md
  docs/异步效果同步写法.md
  docs/{设计说明,API,do语法,工程对接与后续,Unity对接,Lua53兼容性,核心整理说明}.md
  examples/cont_*.lua / coro_*.lua / fx_*.lua / …
  examples/dungeon_raid/     # 地牢突袭综合 demo（GameSim）
  examples/escort_mission/  # 护卫：lanes/proxy/chan/supervise/timeout
  examples/worker_pool/     # 工人池：有界 chan 背压 / map_parallel
  host/unity/             # Unity 对接模板（LuaGameScheduler + C# stub + Mock）
  src/game_sim.lua / scheduler.lua
  tests/run.lua
  tools/mdo.lua
```

---

## 许可

教学示例，随意使用。
