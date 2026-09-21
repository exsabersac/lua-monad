# Changelog

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
