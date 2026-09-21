# fx_api — 每个 fx API 的可运行示例（详细中文注释）

版本对齐工程 **0.2.21-eng**。无 Tab DSL。优先 **Core**；Sugar 文件会写明何时用糖、Core 等价是什么。

在仓库根目录执行。

## 怎么跑

```bash
# 单个文件
lua5.3 examples/fx_api/wait.lua

# 全部
lua5.3 examples/fx_api/main.lua

# 过滤
lua5.3 examples/fx_api/main.lua --filter lane

# CI / 安静冒烟（tests/run.lua 也会调）
lua5.3 examples/fx_api/main.lua test
```

游戏相关等待一律走 **GameSim** / **VirtualClock**（见 `_common.lua`），不对游戏 `wait` 使用墙钟 `busy_wait`。`wait_real` 单独演示 opt-in / unsupported。

## API → 文件

| API | 层 | 文件 |
|-----|----|------|
| `wait` | Core | [`wait.lua`](wait.lua) |
| `wait_event` | Core | [`wait_event.lua`](wait_event.lua) |
| `wait_until` | Core | [`wait_until.lua`](wait_until.lua) |
| `wait_real` | Sugar | [`wait_real.lua`](wait_real.lua) |
| `stop` / `abort` / `fail`（+ `try`） | Core | [`stop_abort_fail.lua`](stop_abort_fail.lua) |
| `fork` / `join` / `join_handles` | Core | [`fork_join.lua`](fork_join.lua) |
| `when_all` / `when_any` | Core | [`when_all_any.lua`](when_all_any.lua) |
| `chan` / `send` / `recv` / `close` | Core | [`chan.lua`](chan.lua) |
| `with_timeout` | Core | [`with_timeout.lua`](with_timeout.lua) |
| `supervise` | Core | [`supervise.lua`](supervise.lua) |
| `register` / `unregister` | Core | [`register.lua`](register.lua) |
| `run` / `set_tracer` | Core | [`run_trace.lua`](run_trace.lua) |
| `with_resource`（`bracket`） | Core | [`with_resource.lua`](with_resource.lua) |
| `seq` | Sugar | [`seq.lua`](seq.lua) |
| `lane*` / `lanes` | Sugar | [`lane.lua`](lane.lua) |
| `proxy*` | Sugar | [`proxy.lua`](proxy.lua) |
| `map_parallel` / `for_each_parallel` | Sugar | [`map_parallel.lua`](map_parallel.lua) |
| `connect` / `click` | Sugar | [`connect_click.lua`](connect_click.lua) |

共用：[`_common.lua`](_common.lua)（`run_sim` / `log` / `need`）、[`main.lua`](main.lua)。

## 文档

- 索引：[`docs/fx示例索引.md`](../../docs/fx示例索引.md)
- 分层：[`docs/fx分层.md`](../../docs/fx分层.md)
- 异步写法：[`docs/异步效果同步写法.md`](../../docs/异步效果同步写法.md)
