# 地牢突袭（Dungeon Raid）

相对完整的 **headless / 确定性** 演示，用 Cont + withEnv + fx + GameSim 串起一场 3 房地下城突袭，用来**展示并校验**工程栈（而非最小片段）。

## 如何运行

```bash
# 仓库根目录
lua examples/dungeon_raid/main.lua          # 中文战报 + 通关
lua examples/dungeon_raid/main.lua test     # 安静自检
lua tests/run.lua                           # 含本 demo 的 focused 测试
```

编程入口：

```lua
package.path = "src/?.lua;examples/dungeon_raid/?.lua;" .. package.path
local DungeonRaid = require("dungeon")
local r = DungeonRaid.run({ quiet = true, assert = true })
assert(r.victory)
```

## 剧情结构

1. **走廊**：1 只地精；怪物 AI `start_flow` + 玩家挥砍（`anim` kind）
2. **旅途**：`fx.wait`；外层 `set_paused` / 恢复（校验 pause 推迟 wait）
3. **骸骨密室**：2 只怪，`when_all` 并行对决
4. **双宝箱**：`map_parallel`，游戏时间 ≈ `max` 而非求和
5. **Boss 厅**：`with_timeout` 读条；默认玩家打断，另测超时 Failed 路径
6. 击杀怪 → `destroy_entity` → AI `finally` 清理 / 掉落标志

## 特性对照表

| 能力 | 本 demo 何处 |
|------|----------------|
| `Cont.withEnv` + 普通步骤 / Cont 步骤 | `dungeon.lua` 主管道 |
| `init` / `finally` | 地牢主管道；每只怪 AI |
| `fx.wait` | 旅途、AI 风摇/冷却、轮询 |
| `fx.wait_event` | `mob_attack` / `boss_interrupt` |
| `fx.when_all` | 双怪并行战斗 |
| `fx.when_any` | 接招 vs 继续挥砍 |
| `fx.fork` / `join_handles` | `combat.fight_mobs_fork_join`（备选 API） |
| `fx.map_parallel` | 双宝箱 |
| `fx.with_timeout` | Boss 读条 |
| `GameSim` spawn/destroy、pause、tick、emit | 全程 |
| `sim:register` 异步 `anim` | 攻击挥砍 |
| `opts.scheduler = sim` | `start_flow` 内置 |

## 模块

| 文件 | 职责 |
|------|------|
| `main.lua` | 可执行入口、叙事打印 |
| `dungeon.lua` | `DungeonRaid.run` / `run_focus` |
| `world.lua` | 世界状态、日志、生成/摧毁 |
| `ai.lua` | 怪物 AI Cont |
| `combat.lua` | 战斗 / 宝箱 / Boss |

默认数值调成 **必胜**；`opts.assert=true` 时检查 pause、finally、宝箱并行、Boss 路径、通关。
