# 工人池（Worker Pool）

用有界 `fx.chan` 做任务队列，演示背压、有限并发工人、`supervise` 脆弱工人与 GameSim 推进。

## 如何运行

```bash
# 仓库根目录
lua examples/worker_pool/main.lua          # 中文日志 + 通关
lua examples/worker_pool/main.lua test     # 安静自检
lua tests/run.lua                          # 含本 demo 的 smoke
```

编程入口：

```lua
package.path = "src/?.lua;examples/worker_pool/?.lua;" .. package.path
local WorkerPool = require("workers")
local r = WorkerPool.run({ quiet = true, assert = true })
assert(r.victory)
```

## 结构

1. **有界 job channel**（默认 cap=2）：生产者 `send`，满则挂起 → **背压**
2. **N 工人**（默认 3）：`recv` → `wait`/`anim` 处理 → `send` 到 result channel
3. **`fx.map_parallel`** 拉起工人；其中 **1 个 flaky** 外包 `fx.supervise`（首次 Failed，重启后恢复）
4. **`fx.lanes`**：`producer` / `workers` / `collector` 三车道汇合
5. job channel `close` 后工人 `recv` 得 `chan_closed` 退出；收集器收齐 N 条后关闭 result channel

## 特性对照表

| 能力 | 本 demo 何处 |
|------|----------------|
| `fx.chan` 有界缓冲 | job_cap=2 背压 |
| `fx.send` / `recv` / `close` | 生产 / 消费 / 收尾 |
| `fx.map_parallel` | 拉起 N 工人 |
| `fx.supervise` | 脆弱工首次失败重启 |
| `fx.lanes` | producer + workers + collector |
| `GameSim` tick / `anim` | 全程游戏时间 |

默认 `n_jobs=8`，数值调成 **快速必胜**；`opts.assert=true` 检查背压、supervise、通关。
