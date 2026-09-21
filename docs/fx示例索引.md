# fx 示例索引（按 API）

版本 **0.2.21-eng**。每个公共 fx API 的可运行示例 + 详细中文注释在：

**[`examples/fx_api/`](../examples/fx_api/)**（[`README`](../examples/fx_api/README.md)）

## 怎么跑

```bash
# 单个 API
lua5.3 examples/fx_api/wait.lua

# 全部 / 过滤 / CI 安静冒烟
lua5.3 examples/fx_api/main.lua
lua5.3 examples/fx_api/main.lua --filter lane
lua5.3 examples/fx_api/main.lua test
```

游戏等待走 **GameSim / VirtualClock**（`_common.lua`），不对游戏 `wait` 使用墙钟 busy_wait。

## API → 文件

| API | 层 | 文件 |
|-----|----|------|
| `wait` | Core | [`wait.lua`](../examples/fx_api/wait.lua) |
| `wait_event` | Core | [`wait_event.lua`](../examples/fx_api/wait_event.lua) |
| `wait_until` | Core | [`wait_until.lua`](../examples/fx_api/wait_until.lua) |
| `wait_real` | Sugar | [`wait_real.lua`](../examples/fx_api/wait_real.lua) |
| `stop` / `abort` / `fail` / `try` | Core | [`stop_abort_fail.lua`](../examples/fx_api/stop_abort_fail.lua) |
| `fork` / `join` / `join_handles` | Core | [`fork_join.lua`](../examples/fx_api/fork_join.lua) |
| `when_all` / `when_any` | Core | [`when_all_any.lua`](../examples/fx_api/when_all_any.lua) |
| `chan` / `send` / `recv` / `close` | Core | [`chan.lua`](../examples/fx_api/chan.lua) |
| `with_timeout` | Core | [`with_timeout.lua`](../examples/fx_api/with_timeout.lua) |
| `supervise` | Core | [`supervise.lua`](../examples/fx_api/supervise.lua) |
| `register` / `unregister` | Core | [`register.lua`](../examples/fx_api/register.lua) |
| `run` / `set_tracer` | Core | [`run_trace.lua`](../examples/fx_api/run_trace.lua) |
| `with_resource` | Core | [`with_resource.lua`](../examples/fx_api/with_resource.lua) |
| `seq` | Sugar | [`seq.lua`](../examples/fx_api/seq.lua) |
| `lane*` / `lanes` | Sugar | [`lane.lua`](../examples/fx_api/lane.lua) |
| `proxy*` | Sugar | [`proxy.lua`](../examples/fx_api/proxy.lua) |
| `map_parallel` | Sugar | [`map_parallel.lua`](../examples/fx_api/map_parallel.lua) |
| `connect` / `click` | Sugar | [`connect_click.lua`](../examples/fx_api/connect_click.lua) |

## 相关文档

- 分层心智：[`fx分层.md`](fx分层.md)
- 异步写法总览：[`异步效果同步写法.md`](异步效果同步写法.md)
- 综合 demo：`examples/dungeon_raid/`、`escort_mission/`、`worker_pool/`（仍保留；按场景而非按 API）
- 旧式单文件：`examples/fx_*.lua`（教学短例，与 fx_api 并存）
