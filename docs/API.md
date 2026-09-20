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

> **Status ≈ Either**：`Ok`/`Err` 已覆盖 `Either e a` / `Result`（失败带载荷并短路）。不另提供 `Either` 模块以免重复。

---

## `Identity` — `src/identity.lua`

值形状：`{ tag="identity", value }`。

| 函数 | 说明 |
|------|------|
| `unit(v)` / `Identity(v)` | 包装 |
| `bind` | `f(ma.value)` |
| `isIdentity(m)` | 谓词 |
| `runIdentity(m)` | 取出 `value` |

---

## `Reader` — `src/reader.lua`

裸值：`function(env) return a end`；对外多为可调用代理。

| 函数 | 说明 |
|------|------|
| `unit(a)` / `Reader(a)` | 忽略环境，结果为 `a` |
| `bind` | 共享同一 `env` 串联 |
| `ask()` | 结果为当前环境 |
| `asks(f)` | 结果为 `f(env)` |
| `localEnv(f, ma)` | 在 `f(env)` 下跑 `ma`（Haskell `local`；`local` 为关键字） |
| `runReader(ma, env)` | → `a` |

---

## `Writer` — `src/writer.lua`

值形状：`{ value=a, log=w }`。默认 string monoid（`""` / `..`）。

| 函数 | 说明 |
|------|------|
| `unit(a)` / `Writer(a)` | `{ value=a, log="" }`（或自定义 `mempty`） |
| `bind` | 拼接左右 `log`（左到右） |
| `tell(w)` | 追加日志；结果 `nil` |
| `listen(ma)` | 结果变为 `{ value=a, log=w }`，日志不变 |
| `pass(ma)` | `ma` 的 value 为 `{a, f}` 或 `{value=a, fn=f}`，用 `f(log)` 改日志 |
| `runWriter(ma)` | → `value, log` |
| `execWriter(ma)` | → `log` |
| `makeWriter` / `withMonoid(monoid)` | 工厂：`{ mempty, mappend }` → 新 Writer 模块 |
| `WriterList` | 预置表列表 Writer（`{}` + 数组拼接） |

---

## `RWS` — `src/rws.lua`

裸值：`function(env, s) return a, s, w end`（默认 `w` 为 string）；对外为可调用代理。

| 函数 | 说明 |
|------|------|
| `unit(a)` / `RWS(a)` | 不改状态、空日志 |
| `ask` / `asks` / `localEnv` | 同 Reader |
| `get` / `put` / `modify` | 同 State |
| `tell(w)` | 追加字符串日志 |
| `runRWS(ma, env, s0)` | → `a, s, w` |
| `evalRWS(ma, env, s0)` | → `a` |
| `execRWS(ma, env, s0)` | → `s, w` |

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
| `throw(e)` | 逃逸到最近 `catch`；无 catch 则 `error("uncaught Cont.throw: …")` |
| `catch(ma, handler)` | `handler(err) → Cont`；handler 栈 + pcall 兜住 Lua error |
| `protect(ma)` | pcall 包住执行；无 catch 时 Lua error → `k({tag="error", error=…})` |
| `reset(ma)` | 定界提示：等同 `evalCont(ma)`（`Cont a a → a`） |
| `shift(f)` | 定界捕获：`f` 收到 `k`，`evalCont(k(x))` 为定界续延作用于 `x` |

`mapCont` vs `withCont`：前者 `f` 包在跑完之后的结果上；后者 `f` 先变换续延再交给计算。示例见 `examples/cont_cps_basics.lua`、`examples/cont_callcc.lua`、`examples/cont_catch_throw.lua`。

| `withEnv(body)` | 见下节 `cont_env`；亦可 `require("cont_env")` 后使用 |
| `finally(ma, cleanup)` | 退出时跑 `cleanup(outcome)`；感知 Cont.throw 与 Coro Done\|Stopped\|Failed（见 `cont_env`） |
| `init_finally(ma, init?, cleanup?)` | 可选 `init()` 先跑，再 `ma`，再 `cleanup` |

---

## `cont_env` — `src/cont_env.lua`（Cont 环境组合）

在 Cont 专用 env 中定义 `a → Cont r b` 步骤，**默认**按首次出现名顺序折成 `Cont.unit(x) >> s1 >> s2 >> …`。无 `ContPipe`。详见 [`Cont环境组合.md`](Cont环境组合.md)。

| 函数 | 说明 |
|------|------|
| `withEnv(body)` | `body(env)` 内写入的函数为步骤；同名替换保序；非函数不当步骤；支持 Helper/Wrap/Before/After/Until/Timeout/Retry/Require/Trace/Catch/**AfterStep/BeforeStep**/**Init/Finally**；固定名 `init`/`finally`；→ `composed` |
| `Cont.withEnv` | 与上同一实现（`cont_env` 加载时挂载；`cont` 首次调用延迟 require） |
| `with_finally(ma, cleanup)` / `Cont.finally` | 包装 Cont：成功 / throw / Coro 终态时跑 cleanup |
| `init_finally(ma, init?, cleanup?)` / `Cont.init_finally` | init 先跑（无参），再 ma，再 cleanup |
| `attrs.__Helper__` / `__NotStep__` | 独立 API：返回 helper sentinel；env 内调用则排队 |
| `attrs.__Init__` / `__Finally__` | 独立 API：返回 init/finally sentinel；env 内排队 |
| `attrs.__Wrap__(w)` | `(w)(step) → new_step` |
| `attrs.__Before__(pre)` / `__After__(post)` | Cont 包装糖；env 内排队 |
| `attrs.__AfterStep__(name)` / `__BeforeStep__(name)` | 管道顺序约束（拓扑）；独立 API 返回描述符；env 内排队 |
| `attrs.__Until__(pred[, max])` | 循环直到 `pred`；默认 max=1000 |
| `attrs.__Timeout__(secs[, on_timeout])` | 合作式超时（步后 `os.clock`）；默认 `{tag="timeout", value, elapsed}` |
| `attrs.__Retry__(n, pred)` | `pred(a)` 则用原 `x` 重试，最多 `n` 次 |
| `attrs.__Require__(pred[, on_fail])` | 步前校验；失败默认 `{tag="rejected", value}` |
| `attrs.__Trace__([label])` | 前后 `print`，值不变 |
| `attrs.__Catch__(handler)` | `Cont.catch(step(x), handler)`；步内 `Cont.throw` / Lua error |

示例：`examples/cont_env_pipe.lua`；属性见 `examples/cont_env_attrs_*.lua` 与 [`Cont环境组合.md`](Cont环境组合.md)。


---

## `Coro` — `src/coro.lua`

建立在 `Cont` 上；答案类型为 `Done | Yielded | Stopped | Failed`。

| 函数 | 说明 |
|------|------|
| `Done(v)` / `Yielded(v, cont)` / `Stopped(reason?)` / `Failed(err)` | 构造答案 |
| `isDone` / `isYielded` / `isStopped` / `isFailed` / `isTerminal` | 谓词 |
| `yield(v)` | → `Cont Answer b`；挂起并交出 `v` |
| `stop(reason?)` | → `Cont Answer b`；不调用 `k`，返回 `Stopped` |
| `fail(err)` | → `Cont Answer b`；不调用 `k`，返回 `Failed` |
| `start(ma)` | 跑 Cont，顶层续延包成 `Done`（或已是 Stopped/Failed） |
| `resume(y, b)` | 将 `b` 喂给 `y.cont` |
| `step(answer, value)` | Done/Stopped/Failed 原样返回；Yielded 则 `resume` |
| `run(ma, handler)` | Done → 最终值；Stopped/Failed → `nil, answer`（**第二返回值**） |
| `runEx(ma, handler)` | → `status, payload`；`status` ∈ `"done"` \| `"stopped"` \| `"failed"` |
| `collect(ma)` | → `yields, final`；若中止则 `yields, nil, answer` |
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

## `fx` — `src/fx.lua`（并行见 `fx_sched.lua`）

教学用效果层（同步写法 / 异步效果）。依赖 Cont + Coro；**非**真实网络/UI，**非**原生 coroutine。

| 函数 | 说明 |
|------|------|
| `fx.wait(seconds)` | yield `{ kind="wait", seconds }`；resume 后 `Cont.unit(true)`（≈ `Task.Delay`） |
| `fx.connect(host, opts?)` | yield `{ kind="connect", host, opts? }`；resume 值为连接结果表 |
| `fx.click(target)` | yield `{ kind="click", target }`；resume 值为点击结果表 |
| `fx.stop(reason?)` | → `Coro.stop`；管道中止为 `Stopped` |
| `fx.fail(err)` / `fx.throw` | → `Coro.fail`；管道失败为 `Failed` |
| `fx.when_all(mas)` / `fx.join_all` | Cont：yield `{kind="when_all",tasks}`；resume → values 数组（≈ `Task.WhenAll`） |
| `fx.when_any(mas)` / `fx.join_any` | Cont：yield `{kind="when_any",tasks}`；resume → `{value,index}`（≈ `Task.WhenAny`） |
| `fx.fork(ma)` / `fx.spawn` | Cont：yield `{kind="fork",task}`；resume → handle `{id=number}`（≈ `Task.Run`） |
| `fx.join(handle, opts?)` | Cont：yield `{kind="join",handle,cancel_siblings?}`；resume → 子 Done 值；`opts.cancel_siblings` 成功后取消同父兄弟 |
| `fx.join_handles(handles, opts?)` | Cont：yield `{kind="join_handles",handles,cancel_siblings?}`；resume → values；可选 `cancel_siblings` |
| `fx.map_parallel(items, worker, opts?)` | 有限并发：`worker(item,index)→Cont Answer a`；`opts.concurrency` 默认 4（>=1）；结果按输入顺序 |
| `fx.for_each_parallel(items, worker, opts?)` | 同 `map_parallel`，丢弃返回值，最终 `true` |
| `fx.with_timeout(ma, seconds, opts?)` | 与 `wait(seconds)` 竞速；超时 → `Failed(opts.on_timeout or "timeout")`；成功则返回 `ma` 的值 |
| `fx.run_parallel(tasks, handlers?, opts?)` | 顶层并行；`opts.mode="all"|"any"`；经 session 时间轮 |
| `fx.run_all` / `fx.run_any` | `run_parallel` 别名 |
| `fx.run(ma, handlers?, opts?)` | nursery session 驱动；`opts.cancel` 时停止全部未完成子任务（取消传播树）；**始终**返回结果表 |
| `fx.try(ma, handlers?, opts)` | 同 `run`；`opts.on_fail` / `opts.on_stop` 可恢复 |

`fx.run` 结果表：`{ok=true,value}` \| `{ok=true,values}` \| `{ok=true,value,index}` \| `{ok=false,stopped=true,reason}` \| `{ok=false,failed=true,error}`。  
旧代码若假定 `fx.run` 直接返回业务值，请改为 `result.value`（破坏性变更）。

详见 [异步效果同步写法.md](./异步效果同步写法.md)。

---

## `mdo` — `src/mdo.lua`（do-notation 预处理 / 加载）

将 `@mdo MONAD … @end` 展开为 `>>` / `..` 嵌套，并可直接加载执行 `.mdo`。详见 [`do语法.md`](do语法.md)。

| 函数 | 说明 |
|------|------|
| `expand(body_src, monad[, base_line])` | 展开 do 正文 → Lua 表达式字符串；`monad` 为上下文名 |
| `preprocess(file_src)` | 替换源码中全部 `@mdo` 块，返回完整 Lua 源 |
| `compile(src[, chunkname])` | 预处理后 `load(..., chunkname, "t")` → function 或 nil, err |
| `loadfile(path)` | 读文件并 compile；chunkname 为 `@path` 或 `@path [mdo]` |
| `dofile(path, ...)` | loadfile 后调用，可变参数传给 chunk（同 Lua `dofile`） |
| `require_searcher(modname)` | package 搜索器：在 `package.path` 的 `?.lua` 旁试 `?.mdo`，并搜 `src/?.mdo`、`examples/?.mdo`、`./?.mdo` |
| `install_loader()` | 幂等把 searcher 插入 `package.searchers`（5.2+）或 `package.loaders`（5.1） |

环境变量：`MDO_CACHE=1` 时，`dofile` 会写同路径旁路 `.lua`（默认关闭）。

CLI：

```bash
lua tools/mdo.lua INPUT.mdo [-o OUTPUT.lua]   # 写 .lua
lua tools/mdo.lua --run|-e INPUT.mdo [args...] # 内存预处理并执行
lua tools/run_mdo.lua INPUT.mdo [args...]      # --run 薄包装
```

`--run` 会设置 `package.path` 含仓库 `src/?.lua`、调用 `install_loader()`，再 `dofile`。
