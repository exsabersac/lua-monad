# Changelog

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
