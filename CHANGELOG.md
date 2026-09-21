# Changelog

## 0.2.7-eng — 2026-09-21

- **监督式重启（P2）**：`fx.supervise(child_ma, opts?)`
  - `opts.max_restarts`（默认 **3**）、`opts.backoff`（默认 **0**，游戏秒，经 scheduler wait）
  - `opts.restart_if(err)` / `opts.on_fail(err)`（返回 `false` 则不再重启）
  - 默认仅 **Failed** 重启；`opts.restart_on_stop` 可选对 Stopped（非 cancelled）重启；**Aborted** 不重启
  - cancel / force_stop supervise：取消当前子与 backoff，**不再重启**
  - 与 finally / iquit 对齐：每次子尝试独立跑生命周期
- Session yield：`supervise`；`fx_registry.STANDARD_KINDS.supervise`
- 文档：异步效果 / 工程可用验收 / API / 工程对接；测试覆盖 VirtualClock + GameSim

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
