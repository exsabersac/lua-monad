# tools/

仓库根目录下运行（`package.path` 已含 `src/?.lua`）。目标解释器：**Lua 5.3**。

| 工具 | 作用 |
|------|------|
| [`bench_cont_fx.lua`](bench_cont_fx.lua) | Cont / `>>` / chain / `fx.seq` / session / **lane·proxy·chan·supervise·wait_until·when_all** 热路径粗测（时间 + ΔKB；`--json` / `--filter`） |
| [`flow_doctor.lua`](flow_doctor.lua) | 常见误配置检查：未知 kind → Failed、wait 无 scheduler 提示、打印 `STANDARD_KINDS`；`--` + `strict` 供 CI |
| [`trace_dump.lua`](trace_dump.lua) | 演示 `opts.trace`：打印 flow 追踪事件（文本或 `--json`；可选 `--lane` / `--chan`） |
| [`mdo.lua`](mdo.lua) / [`run_mdo.lua`](run_mdo.lua) | `@mdo` 预处理与 runner |

性能数字与解读见 [`docs/性能与工具.md`](../docs/性能与工具.md)。

## bench_cont_fx

```bash
lua5.3 tools/bench_cont_fx.lua              # 默认 N=20000（重用例内部 clamp）
lua5.3 tools/bench_cont_fx.lua 50000
lua5.3 tools/bench_cont_fx.lua --json
lua5.3 tools/bench_cont_fx.lua --filter lane
lua5.3 tools/bench_cont_fx.lua --json --filter chan 5000
lua5.3 tools/bench_cont_fx.lua --help
```

关注列（名称可用 `--filter` 子串匹配）：

| 名称 | 含义 |
|------|------|
| **Cont >> chain** | 典型 `ma >> f`（每步 unit + bind） |
| **Cont.map chain** | 无每步 unit 的映射链 |
| **Cont.chain / Cont ..** | 丢弃左值的轻量串联（`fx.seq` 同路径） |
| **fx.seq×3 eval** | 仅构造 + `evalCont`（无 session） |
| **fx.seq×3 run** | 经 `fx.run` → session（含同步快路径） |
| **session wait(0)** | VirtualClock 会话 |
| **fx.lane+join** | 命名 lane 启动 + join |
| **fx.proxy_join** | 经 lane 的 proxy join |
| **fx.chan VC / GameSim** | channel send/recv（VirtualClock / GameSim） |
| **fx.supervise** | 失败一次后重启成功 |
| **fx.wait_until triv** | 平凡 pred（立刻真） |
| **when_all waits** | 两路 wait 的 `when_all` |

`--json` 每行一个对象：`name` / `n` / `sec` / `rate` / `dkb`（可选 `note`）。  
非严格 microbench（含 GC）。

## flow_doctor

```bash
lua5.3 tools/flow_doctor.lua
lua5.3 tools/flow_doctor.lua --kinds          # 仅列出 STANDARD_KINDS
lua5.3 tools/flow_doctor.lua --ci            # 同 CI 模式（别名）
# CI：硬检查失败 exit 1（flag 名见 --help；亦支持 --ci）
lua5.3 tools/flow_doctor.lua --help
```

检查项：

1. **未知 yield kind** → 期望 `Failed{tag=unknown_effect, effect_kind=…}`
2. **wait 无 `opts.scheduler`** → `[WARN]` busy_wait / 演示路径（工程应注入 VirtualClock / GameSim / Unity scheduler）
3. **打印 `fx_registry.STANDARD_KINDS`**，并确认关键 kind 存在

CI 模式（`--ci` 或帮助里的同类 flag）：仅当硬检查 `[FAIL]` 时非零退出；`[WARN]` 不导致失败。

## trace_dump

```bash
lua5.3 tools/trace_dump.lua
lua5.3 tools/trace_dump.lua --json
lua5.3 tools/trace_dump.lua --wait 0.05
lua5.3 tools/trace_dump.lua --lane            # 额外 dump lane fork/join（事件含 lane=）
lua5.3 tools/trace_dump.lua --chan            # 额外 dump chan_send/recv
lua5.3 tools/trace_dump.lua --lane --chan --json
lua5.3 tools/trace_dump.lua --help
```

注意：`opts.trace` **必须是 function**；传 `true` 会被忽略。全局可用 `fx.set_tracer` / `Sched.set_tracer`。  
lane / chan / supervise 等事件已由 session 发出；本工具只负责 dump。

## mdo

```bash
lua5.3 tools/run_mdo.lua examples/...   # 视仓库内示例而定
```

详见 [`docs/do语法.md`](../docs/do语法.md)。
