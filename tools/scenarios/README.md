# tools/scenarios/

小型可复用 Cont/fx 场景模块，供 `profile_flow` / `trace_export` / `bench_cont_fx` 等共用，避免各工具重复拼装。

| 模块 | `id` | 展示名 `name` | 含义 |
|------|------|---------------|------|
| [`sync_seq.lua`](sync_seq.lua) | `sync_seq` | sync seq | 纯同步 `fx.seq`×3 |
| [`wait_vc.lua`](wait_vc.lua) | `wait_vc` | wait VirtualClock | `fx.wait` + unit（需 scheduler） |
| [`lane_pair.lua`](lane_pair.lua) | `lane_pair` | lane | 命名 lane + `lane_join` |
| [`chan_ping.lua`](chan_ping.lua) | `chan_ping` | chan | fork(send) → recv → join |
| [`supervise_once.lua`](supervise_once.lua) | `supervise_once` | supervise once | fail 一次后成功 |

入口：[`init.lua`](init.lua) → `require("scenarios")`。

```lua
package.path = "src/?.lua;tools/?.lua;tools/?/init.lua;" .. package.path
local Scenarios = require("scenarios")
local ma = Scenarios.by_id.sync_seq.build()
-- 或
local ma = Scenarios.get("lane").build({ lane = "demo", value = 42 })
```

每个模块导出：`id` / `name` / `needs_scheduler` / `build(opts?) → Cont`。  
**无 Tab DSL**；仅 Cont/fx 原语。
