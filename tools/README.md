# tools/

仓库根目录下运行（`package.path` 已含 `src/?.lua`）。目标解释器：**Lua 5.3**。

| 工具 | 作用 |
|------|------|
| [`bench_cont_fx.lua`](bench_cont_fx.lua) | Cont / `>>` / chain / `fx.seq` / session / **lane·proxy·chan·supervise·wait_until·when_all** 热路径粗测（时间 + ΔKB；`--json` / `--filter` / `--alloc`） |
| [`bench_compare.lua`](bench_compare.lua) | 跑当前 bench `--json`，对照 [`bench_baseline.json`](bench_baseline.json)；`--write-baseline` / `--ci` 回归 |
| [`bench_baseline.json`](bench_baseline.json) | 本机 Lua 5.3 粗测基线（由 `--write-baseline` 生成） |
| [`alloc_hotspot.lua`](alloc_hotspot.lua) | Cont `>>` 链分配热点：`collectgarbage("count")` before/after + 表计数启发式 |
| [`flow_doctor.lua`](flow_doctor.lua) | 常见误配置检查：未知 kind → Failed、wait 无 scheduler 提示、打印 `STANDARD_KINDS`；`--` + `strict` 供 CI |
| [`trace_dump.lua`](trace_dump.lua) | 演示 `opts.trace`：打印 flow 追踪事件（文本或 `--json`；可选 `--lane` / `--chan`） |
| [`trace_export.lua`](trace_export.lua) | 小型 Cont/fx 场景 + `opts.trace` → JSON 文件（默认 `tools/trace_out.json`；`--lane` / `--chan` / `--out`） |
| [`bench_summary.lua`](bench_summary.lua) | 从 `bench_cont_fx --json`（或 stdin/文件）生成 Markdown 表；`--out tools/bench_summary.md` |
| [`mdo.lua`](mdo.lua) / [`run_mdo.lua`](run_mdo.lua) | `@mdo` 预处理与 runner |

性能数字与解读见 [`docs/性能与工具.md`](../docs/性能与工具.md)。

## bench_cont_fx

```bash
lua5.3 tools/bench_cont_fx.lua              # 默认 N=20000（重用例内部 clamp）
lua5.3 tools/bench_cont_fx.lua 50000
lua5.3 tools/bench_cont_fx.lua --json
lua5.3 tools/bench_cont_fx.lua --filter lane
lua5.3 tools/bench_cont_fx.lua --alloc --json --filter 'Cont >>'
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

`--json` 每行一个对象：`name` / `n` / `sec` / `rate` / `dkb` / **`kb_delta`**（= `dkb`；可选 `note`）。  
`--alloc`：文本多打 `alloc[KB before/after/Δ]`；JSON 额外 `kb_before` / `kb_after`。  
非严格 microbench（含 GC）。

## bench_compare / baseline

对照仓库内基线、写基线、CI 回归（默认阈值 **25% slower**；关注 `Cont >> chain` / `fx.seq×3 run` / `fx.seq×3 eval`）。

```bash
# 跑当前 bench 并与 tools/bench_baseline.json 比 Δ%
lua5.3 tools/bench_compare.lua
lua5.3 tools/bench_compare.lua 20000

# 用本机 lua5.3 重写基线（提交前 / 换机器后）
lua5.3 tools/bench_compare.lua --write-baseline
lua5.3 tools/bench_compare.lua --write-baseline --baseline tools/bench_baseline.json 20000

# CI：关键用例 sec 相对基线增幅 > threshold → exit 1
lua5.3 tools/bench_compare.lua --ci
lua5.3 tools/bench_compare.lua --ci --threshold 0.25
lua5.3 tools/bench_compare.lua --ci --all          # 检查全部有基线的用例
lua5.3 tools/bench_compare.lua --filter 'Cont >>' --ci

lua5.3 tools/bench_compare.lua --help
```

| 选项 | 含义 |
|------|------|
| `--write-baseline` | 跑 `bench_cont_fx --json` 后写入 baseline |
| `--baseline PATH` | baseline 路径（默认 `tools/bench_baseline.json`） |
| `--threshold F` | 回归阈值（默认 `0.25` = 25% 更慢） |
| `--ci` | 无 baseline 或关键项回归超阈值 → 非零退出 |
| `--all` | CI 时对全部用例检查（不仅关键三项） |
| `--filter NAME` | 转发给 bench |

输出列：`sec` / `base` / `Δsec%` / `Δrate%` / `Δkb%` / `flag`（`ok` / `faster` / `REGRESS` / `new`；N 不一致时带 `!N`）。  
**请用与 baseline 相同的 N**（默认 20000；重用例内部仍 clamp）。

## alloc_hotspot

```bash
lua5.3 tools/alloc_hotspot.lua           # 默认 N=5000，Cont >> 链
lua5.3 tools/alloc_hotspot.lua 10000
lua5.3 tools/alloc_hotspot.lua --map     # 额外 Cont.map 对照
lua5.3 tools/alloc_hotspot.lua --json 5000
lua5.3 tools/alloc_hotspot.lua --help
```

报告 `collectgarbage("count")` 的 KB before / after / Δ，以及弱表登记的 **表创建启发式**（相对参考，非精确 heap 表数）。  
更全的用例仍用 `bench_cont_fx.lua --alloc`。

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

## trace_export

把 `opts.trace` 事件收集进 **JSON 文件**（对照 `trace_dump` 的 stdout dump）。

```bash
lua5.3 tools/trace_export.lua
lua5.3 tools/trace_export.lua --lane --chan
lua5.3 tools/trace_export.lua --out /tmp/trace.json
lua5.3 tools/trace_export.lua --lane --chan --out tools/trace_out.json --stdout
lua5.3 tools/trace_export.lua --wait 0.05 --help
```

默认路径 `tools/trace_out.json`（已在 `.gitignore`）。输出形状：`{"meta":{…},"events":[{…},…]}`。  
`opts.trace` **必须是 function**。

## bench_summary

从 bench NDJSON 生成 Markdown 表（可提交 `tools/bench_summary.md` 或仅打印）。

```bash
lua5.3 tools/bench_summary.lua                              # 内部跑 bench --json，打印 MD
lua5.3 tools/bench_summary.lua --out tools/bench_summary.md
lua5.3 tools/bench_summary.lua 5000 --out tools/bench_summary.md
lua5.3 tools/bench_cont_fx.lua --json | lua5.3 tools/bench_summary.lua --stdin
lua5.3 tools/bench_summary.lua --from /tmp/bench.ndjson --out tools/bench_summary.md
lua5.3 tools/bench_summary.lua --filter 'Cont >>' --out tools/bench_summary.md
lua5.3 tools/bench_summary.lua --help
```

列：`name` / `n` / `sec` / `rate` / `kb_delta`。

## ci_tools（scripts/）

仓库根一键：

```bash
./scripts/ci_tools.sh
ALLOW_BENCH_REGRESSION=1 ./scripts/ci_tools.sh   # bench --ci 回归时 soft-fail
```

顺序：`test_lua53.sh` → `flow_doctor --ci` → `bench_compare --ci` → `alloc_hotspot` smoke（N=100）。

## mdo

```bash
lua5.3 tools/run_mdo.lua examples/...   # 视仓库内示例而定
```

详见 [`docs/do语法.md`](../docs/do语法.md)。
