# tools/

仓库根目录下运行（`package.path` 已含 `src/?.lua`）。目标解释器：**Lua 5.3**。

| 工具 | 作用 |
|------|------|
| [`bench_cont_fx.lua`](bench_cont_fx.lua) | Cont `>>` / `Cont.chain` / `fx.seq` / session 热路径粗测（时间 + 内存 ΔKB） |
| [`trace_dump.lua`](trace_dump.lua) | 演示 `opts.trace`：打印 flow 追踪事件（文本或 `--json`） |
| [`mdo.lua`](mdo.lua) / [`run_mdo.lua`](run_mdo.lua) | `@mdo` 预处理与 runner |

## bench_cont_fx

```bash
lua5.3 tools/bench_cont_fx.lua          # 默认 N=20000
lua5.3 tools/bench_cont_fx.lua 50000
```

关注列：

- **Cont >> chain** — 典型 `ma >> f`（每步 unit + bind）
- **Cont.chain / Cont ..** — 丢弃左值的轻量串联（`fx.seq` 同路径）
- **fx.seq×3 eval** — 仅构造 + `evalCont`（无 session）
- **fx.seq×3 run** — 经 `fx.run` → session（含调度开销）
- **session wait(0)** — VirtualClock 会话

非严格 microbench（含 GC）。数字与优化说明见 [`docs/性能与工具.md`](../docs/性能与工具.md)。

## trace_dump

```bash
lua5.3 tools/trace_dump.lua
lua5.3 tools/trace_dump.lua --json
lua5.3 tools/trace_dump.lua --wait 0.05
lua5.3 tools/trace_dump.lua --help
```

注意：`opts.trace` **必须是 function**；传 `true` 会被忽略。全局可用 `fx.set_tracer` / `Sched.set_tracer`。

## mdo

```bash
lua5.3 tools/run_mdo.lua examples/...   # 视仓库内示例而定
```

详见 [`docs/do语法.md`](../docs/do语法.md)。
