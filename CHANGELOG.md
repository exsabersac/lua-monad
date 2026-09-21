# Changelog

## 0.2.19-eng — 2026-09-21

### Refactor（行为保持）
- **`drive_until_block` 按 kind 拆分**：`fx_sched_drive.lua` 薄分派（~111 行）+ `S.drive_handlers` 表
- 新增 `fx_sched_drive_{wait,fork,lane,proxy,chan,registry}.lua`：wait* / fork-join·when_*·supervise·timeout / lane* / proxy* / chan* / Registry 兜底
- `lane_join` / `proxy_join`（同 nursery 已结束子）统一走 `apply_finished_child_to_waiter`
- 文档：[`docs/核心整理说明.md`](docs/核心整理说明.md)；`require("fx_sched")` API / Lua 5.3 测试与 dungeon·escort·worker smoke 不变

## 0.2.18-eng — 2026-09-21

### Refactor（行为保持）
- **`fx_sched` 拆分**：薄编排 `fx_sched.lua` + `fx_sched_util` / `chan` / `nursery` / `supervise` / `drive` / `session`；共享袋 `S` 晚绑定
- **去重**：`arm_scheduler_timer`、`apply_finished_child_to_waiter`、`settle_group` 失败分支合并
- **`fx.lua`**：`lane_stop`/`lane_abort`、`proxy_stop`/`proxy_abort`、`run_all`/`run_any` 收成薄包装
- 文档：[`docs/核心整理说明.md`](docs/核心整理说明.md)；公共 API / Lua 5.3 测试与示例不变

## 0.2.17-eng — 2026-09-21

### Examples
- 新增 `examples/escort_mission/`：护卫任务综合 demo（`fx.lane` / `fx.proxy` / `fx.chan` / `fx.supervise` / `with_timeout` / GameSim pause·destroy·finally；中文 `[模拟 Xs]` 战报；`run({quiet,assert})`）
- 新增 `examples/worker_pool/`：有界 channel 工人池（背压、`map_parallel`、脆弱工 `supervise`、`fx.lanes` 汇合；GameSim tick；中文日志）
- `tests/run.lua` 接入两例 quiet assert smoke
- README / [`docs/版本与路线.md`](docs/版本与路线.md) 入口与版本表更新

## 0.2.16-eng — 2026-09-21

- **性能基线刷新**
  - 本机重种 [`tools/bench_baseline.json`](tools/bench_baseline.json)：`lua5.3 tools/bench_compare.lua --write-baseline`（默认 N=20000）
- **工具套件收口文档**
  - 新增 [`docs/工具套件收口.md`](docs/工具套件收口.md)：全工具 inventory（bench / compare / alloc / doctor / trace_dump·export / profile_flow / scenarios / ci_tools / mdo）、日常与 CI 工作流、**游戏时间勿用 `fx.wait_real`**
  - [`docs/版本与路线.md`](docs/版本与路线.md) 增「工具套件」节并标记 eng 工具波次完成
- **无 Tab DSL**；eng 工具波次视为完成（再发现 bug 按单点修）

## 0.2.15-eng — 2026-09-21

- **共享场景模块（`tools/scenarios/`）**
  - 新增可复用 Cont/fx 场景：`sync_seq` / `wait_vc` / `lane_pair` / `chan_ping` / `supervise_once`
  - 入口 `require("scenarios")`（`list` / `by_id` / `get` / `filter`）；各模块 `build(opts?) → Cont`
  - `profile_flow` / `trace_export` / `bench_cont_fx`（重叠用例）改为 require 场景，避免重复拼装
  - `profile_flow` 增场景 **supervise once**；`--filter` 可匹配展示名或 id
- **文档**
  - 新增一页速查 [`docs/工具速查.md`](docs/工具速查.md)（全工具 copy-paste 命令）
  - README / [`tools/README.md`](tools/README.md) / [`docs/性能与工具.md`](docs/性能与工具.md) 链接与版本刷新
- **无 Tab DSL**；仅 Cont/fx 原语


## 0.2.14-eng — 2026-09-21

- **profile_flow（场景打点）**
  - 新增 `tools/profile_flow.lua`：wrapping `opts.trace`，每事件记录 `os.clock`（有 luasocket 时墙钟 `socket.gettime`）
  - 相邻 Δ 归入 yield kind（无则 `type`；有 `step`/`name`/`lane` 附带 `step=`）；打印 top kinds by total time
  - 场景：`sync seq` / `wait VirtualClock` / `lane` / `chan`；`--json` / `--out` / `--smoke` / `--filter` / `--top`
- **CI**
  - `scripts/ci_tools.sh` 末步始终 `profile_flow --smoke`（N=1）；`PROFILE=1` 时 N=20
- 文档：[`tools/README.md`](tools/README.md)、[`docs/性能与工具.md`](docs/性能与工具.md)

## 0.2.13-eng — 2026-09-21

- **CI 工具链**
  - 新增 `scripts/ci_tools.sh`：按序跑 `test_lua53.sh` → `flow_doctor --ci` → `bench_compare --ci` → `alloc_hotspot` smoke
  - `ALLOW_BENCH_REGRESSION=1` 时 bench 回归 soft-fail（其余步骤仍硬失败）
- **trace 导出**
  - 新增 `tools/trace_export.lua`：跑小型 Cont/fx 场景，经 `opts.trace` 收集事件写入 JSON（默认 `tools/trace_out.json`）
  - 支持 `--lane` / `--chan` / `--out PATH` / `--wait` / `--stdout`
- **bench Markdown 摘要**
  - 新增 `tools/bench_summary.lua`：从 `bench_cont_fx --json`（或 `--stdin` / `--from`）生成 Markdown 表；`--out tools/bench_summary.md`
- 文档：[`tools/README.md`](tools/README.md)、[`docs/性能与工具.md`](docs/性能与工具.md)

## 0.2.12-eng — 2026-09-21

- **性能基准对照**
  - 新增 `tools/bench_compare.lua`：跑当前 `bench_cont_fx --json`，对照 `tools/bench_baseline.json`，打印 `Δsec%` / `Δrate%` / `Δkb%`
  - `--write-baseline` 种子/更新基线；`--ci` 时关键项（`Cont >> chain` / `fx.seq×3 run` / `fx.seq×3 eval`）变慢超过阈值（默认 **25%**）则非零退出；`--threshold` / `--all` / `--filter`
  - 提交本机 Lua 5.3 种子基线 `tools/bench_baseline.json`
- **分配可观测**
  - `bench_cont_fx`：JSON 始终含 **`kb_delta`**（= `dkb`）；新增 `--alloc`（文本 before/after；JSON 多 `kb_before`/`kb_after`）
  - 新增 `tools/alloc_hotspot.lua`：Cont `>>` 链 `collectgarbage("count")` + 弱表计数启发式（可选 `--map`）
- 文档：[`tools/README.md`](tools/README.md)、[`docs/性能与工具.md`](docs/性能与工具.md)

## 0.2.11-eng — 2026-09-21

- **性能基准扩展**（`tools/bench_cont_fx.lua`）
  - 新增用例：`fx.lane+join`、`fx.proxy_join`、`fx.chan`（VirtualClock / GameSim）、`fx.supervise`（fail→ok）、`fx.wait_until` 平凡 pred、`when_all` of waits
  - 保留 Cont / `>>` / map / chain / `fx.seq` / session wait(0)
  - CLI：`--json`（machine-readable）、`--filter NAME`；重用例内部 N clamp
- **周边工具**
  - 新增 `tools/flow_doctor.lua`：未知 kind → Failed、wait 无 scheduler WARN、打印 `STANDARD_KINDS`；CI 模式（`--ci` / 帮助中的同类 flag）
  - `tools/trace_dump.lua`：可选 `--lane` / `--chan` 演示相关 trace 事件
  - `tools/README.md` 全面更新
- 文档：[`性能与工具.md`](docs/性能与工具.md) 刷新版本与新表；README 工具入口

## 0.2.10-eng — 2026-09-21

- **轻量 flow/lane proxy（≈ tabMachine tabProxy）**
  - `fx.proxy(name|handle|flow, opts?)`：外部 wait/stop 句柄，**不拥有** Cont
  - `flow:proxy(opts?)`：整段 session 的 proxy
  - `fx.proxy_join(p)`：等到目标 Done/Failed/Stopped/Aborted（复用 fork/join `joiners`）
  - `fx.proxy_stop(p)` / `fx.proxy_abort(p)`：合作式停止 / 异常中止；resume `true`/`false`
  - `opts.stop_host_when_stop`：`proxy_join` 等待方被取消时反向停止目标（≈ tabProxy 反向链接）
  - 未知目标 → Failed `{tag=proxy_unknown}`；跨 session 等 flow 经 `_proxy_joiners` 唤醒
- Session yield：`proxy_join` / `proxy_stop` / `proxy_abort`；`fx_registry.STANDARD_KINDS`
- 文档：[`tabMachine对照.md`](docs/tabMachine对照.md) 映射 tabProxy；API / 验收
- 测试：名/handle/flow join、stop/abort、unknown、跨 session、stop_host_when_stop

## 0.2.9-eng — 2026-09-21

- **命名 lane（轻量 tabMachine 多行）**
  - `fx.lane(name, ma)`：命名 fork；`session.lanes[name]=task_id`；立刻 resume `{id,name}`
  - `fx.lane_join(name)` / `fx.lane_stop` / `fx.lane_abort`：按名等待 / 停止(Stopped) / 中止(Aborted)
  - `fx.lanes({ s=ma1, t=ma2 })`：全部命名启动 + `join_handles` 汇合 → `{ s=…, t=… }`
  - 同名在跑 → Failed `{tag=lane_busy}`；未知名 join → `{tag=lane_unknown}`
  - 复用既有 fork/join nursery；无 tab 代理 DSL
- Session yield：`lane` / `lane_join` / `lane_stop` / `lane_abort`；`fx_registry.STANDARD_KINDS`
- 文档：[`tabMachine对照.md`](docs/tabMachine对照.md) 映射 `c:start("t1")`；API / 验收
- 测试：命名启停、lanes 汇合、busy/unknown、abort 传播


## 0.2.8-eng — 2026-09-21

- **Unity host 强化**：`host/unity/`
  - `LuaGameScheduler.lua`：xLua 接线注释；可选转发 `host.schedule_real` → `sched.schedule_real`
  - 新增 **`FxUnityBootstrap.lua`**：`bootstrap(host)` / `from_global` 自动填 `fx.run` / `start_session` 的 `opts.scheduler`
  - `UnityGameScheduler.cs.txt`：补全 xLua `InjectIntoLua` / `ScheduleLua` / **`ScheduleLuaReal`**（墙钟）示例
  - `README.md`：拷贝清单（copy-paste checklist）
- **可选墙钟 `fx.wait_real(seconds)`**（默认业务禁用）
  - yield kind `wait_real`；兑现顺序：`scheduler.schedule_real` → 否则 `opts.allow_real_time` busy_wait → 否则 **Failed** `{tag=wait_real_unsupported}`
  - `fx_registry.STANDARD_KINDS.wait_real`；MockUnityHost / VirtualClock 无 `schedule_real` 时清晰失败
  - 测试：unsupported 路径 + `allow_real_time` + `schedule_real` / Bootstrap 接线
- 文档：验收 / 工程对接 / Unity对接 / API；版本号 → `0.2.8-eng`


## 0.2.7-eng — 2026-09-21

- **监督式重启（P2）**：`fx.supervise(child_ma, opts?)`
  - `opts.max_restarts`（默认 **3**）、`opts.backoff`（默认 **0**，游戏秒，经 scheduler wait）
  - `opts.restart_if(err)` / `opts.on_fail(err)`（返回 `false` 则不再重启）
  - 默认仅 **Failed** 重启；`opts.restart_on_stop` 可选对 Stopped（非 cancelled）重启；**Aborted** 不重启
  - cancel / force_stop supervise：取消当前子与 backoff，**不再重启**
  - 与 finally / iquit 对齐：每次子尝试独立跑生命周期
- Session yield：`supervise`；`fx_registry.STANDARD_KINDS.supervise`
- 文档：异步效果 / 工程可用验收 / API / 工程对接；测试覆盖 VirtualClock + GameSim
- **地牢突袭 showcase 接入**：萨满图腾用 `fx.supervise(max_restarts=1)` 从一次确定性 `Failed` 恢复；宝箱奖励用 `fx.chan` 做通知并在日志中展示。

## 0.2.6-eng — 2026-09-21

- **有界 channel / mailbox（P2）**：`fx.chan(n?)`（默认容量 **1**；`0`=会合）、`fx.send` / `fx.recv` / `fx.close` / `fx.is_closed`
- Session yield：`chan_send` / `chan_recv` / `chan_close`；调度器在 peer 进展时唤醒等待方（GameSim 无 busy_wait）
- cancel / `force_stop` 从 channel 队列摘掉 waiter → **Stopped**
- 关闭：等待中的 send → `Failed{tag=chan_closed}`；缓冲排空后 recv 同
- 文档：异步效果 / 工程可用验收 / API / 工程对接；示例 `game_sim_parallel` 轻量扩展
- 测试：`fx.chan` 缓冲、跨 flow、cancel、close、容量 0

## 0.2.5-eng — 2026-09-21

- **同步快路径**：`fx_sched.start_session` / `run_session` — `Coro.start` 立刻终态（未 Yield）则跳过 nursery/pump；Yielded 注入既有 session（wait/fork/timeout/cancel/finally/iquit 不变）
- `fx.seq×3 run` 粗测约 **22×**（相对 0.2.4）；见 [`docs/性能与工具.md`](docs/性能与工具.md)
- 测试：sync fast-path 回归（seq/fail/stop/cancel/trace/finally + yield 仍有 nursery）

## 0.2.4-eng — 2026-09-21

- **Cont 热路径**：专用 `bind`（少 adapter；已 wrap 直调 `_fn`）；新增 **`Cont.chain`**；`..` 走 chain；**`map`/`then_`/`fmap`** 避免 bind+unit 双代理
- **`fx.seq`** 改为 `Cont.chain` 串联
- 工具：`tools/README.md`；`bench_cont_fx.lua` 增 map/chain/seq·eval 与 ΔKB；`trace_dump.lua` 统一参数与 `--help`
- 文档：[`docs/性能与工具.md`](docs/性能与工具.md)（前后粗测）；验收 / API / tabMachine 对照同步

## 0.2.3-eng — 2026-09-21

- **abort vs stop**：`fx.abort` / `Coro.Aborted`；`fx.stop` 仍为 Stopped；cancel/`force_stop` 仍 Stopped
- fork 子 **abort** → `join` / `when_all` / `when_any` 传播 `aborted`（不算成功值）；见 [`docs/tabMachine对照.md`](docs/tabMachine对照.md)
- **iquit**：固定名 `iquit`/`__iquit__`、`__IQuit__`；`Cont.with_iquit` / `Cont.iquit_finally`；quit 路径 **先于** finally，Done 跳过
- **`fx.seq(mas)`**：左→右串联（≈ tabMachine `..` / g_t.seq）
- **suspend/resume**：`flow:suspend()` / `flow:resume()`；`GameSim:suspend_flow` / `resume_flow`（按 flow 冻结 wait 兑现）
- 工具：`tools/bench_cont_fx.lua`（热路径粗测）、`tools/trace_dump.lua`（trace 事件 dump）
- 验收 / README / 对照文档同步


## 0.2.2-eng — 2026-09-21

- **`fx.wait_until(pred, opts?)`**：每 tick（或 `opts.interval`）poll 谓词；真值 resume 该返回值
- **`FrameScheduler`**（`scheduler.lua`）：`now` / `schedule` / `cancel` / `tick(dt)`，tick 推进时间、到期 timer，并跑 `schedule_poll`（wait_until）
- **GameSim**：同契约 `schedule_poll`；`tick` 内 poll wait_until（与 FrameScheduler 互为宿主）
- 无 `schedule_poll` 的 Scheduler（如 VirtualClock）：用 `schedule` 自再预约模拟 poll
- 无 scheduler：演示回退 busy 轮询（工程路径请接 FrameScheduler / GameSim）
- 验收清单 / 工程对接文档：wait_until、FrameScheduler 标为已落地

## 0.2.1-eng — 2026-09-21

- **截止时间向下传播**：`fx.with_timeout` / `opts.timeout` / `opts.deadline` 将绝对截止写入任务；`fork` / `when_all` / `when_any` 子任务继承剩余 deadline（有 scheduler 时为游戏时间）
- 父 deadline 触发：包装侧 `Failed`；未完成后代递归 `Stopped`（`force_stop` → finally / bracket release）
- 子可再用更紧的 `with_timeout`（取 min）
- 嵌套 `Cont.bracket`：文档注记 + 测试（内层 release 先于外层）
- 验收清单 / 异步效果文档同步

## 0.2.0-eng — 2026-09-21

工程可用增量（Unity + Lua 5.3 目标）：

- **效果注册表** [`src/fx_registry.lua`](src/fx_registry.lua)：`fx.register` / `fx.unregister`；`STANDARD_KINDS` 文档；未知 kind → 结构化 `Failed`（非静默、非 assert 崩进程）
- **实体绑定** [`src/fx_flow.lua`](src/fx_flow.lua)：`fx.bind_entity` / `start_flow` / `start_bound_flow`；`GameSim:start_flow` 复用
- **资源 bracket**：`fx.with_resource` / `Cont.bracket`（Done / Stopped / Failed 皆 release）
- **轻量追踪**：`opts.trace` / `fx.set_tracer`（默认关闭）；事件 flow_start / yield / resume / fork / join / cancel / done|failed|stopped
- **脚本**：`scripts/test_lua53.sh`
- **文档**：`docs/工程可用验收.md`；更新 `工程对接与后续.md`；Unity host 注释对齐

## 0.1.x — 此前

Cont / Coro / withEnv / fx 并行与 fork-join、GameSim、地牢突袭 demo、Unity host 模板、Lua 5.3 兼容说明。详见 git 历史。
