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

1. **走廊（刺客）**：`assassin` AI — 潜行 → `when_any(player_slash, ambush_delay)` 伏击或被识破 → 普攻
2. **旅途**：`fx.wait`；外层 `set_paused` / 恢复（校验 pause 推迟 wait）
3. **骸骨密室（狂战士 + 萨满）**：两只复杂 AI 并行，`when_all` 对决
4. **双宝箱**：`map_parallel`，游戏时间 ≈ `max` 而非求和
5. **Boss 厅**：`with_timeout` 读条；默认玩家打断，另测超时 Failed 路径
6. 击杀怪 → `destroy_entity` → AI `finally` 清理 / 掉落标志

## 复杂怪物 AI（`ai.lua`）

| AI (`mob.ai`) | 行为要点 | 展示的 Cont/fx 能力 |
|---------------|----------|---------------------|
| `basic` / 默认 / `boss` | 风摇 → `mob_attack` → 冷却，循环至销毁 | `wait` / `emit` / `finally` |
| `berserker` 狂战士 | 每轮查 `hp≤50%` → 日志暴怒、缩短 windup、提高 atk；直至 destroy → finally | 相位（轮询 hp）、状态突变 |
| `shaman` 萨满 | 引导：`emit mob_cast_start` + `when_any(wait(cast), wait_event player_slash)`；成功自疗；偶发 `spawn_mob`+`AI.start(basic)`；finally 清残留召唤物 | 可打断读条、`wait_event`、召唤与 cleanup |
| `assassin` 刺客 | 短暂潜行 → `when_any(被砍, 延时伏击 1.5×)` → 失败则转入普攻 | 重度 `when_any` |

玩家挥砍命中时 `combat.fight_one` 会 `sim:emit("player_slash", { id, target_id })`，供萨满打断与刺客窗口监听。

校验标志（`world.checks`）：`berserker_enraged` / `shaman_interrupted` / `assassin_ambush`（完整通关至少其一为真）。

## 特性对照表

| 能力 | 本 demo 何处 |
|------|----------------|
| `Cont.withEnv` + 普通步骤 / Cont 步骤 | `dungeon.lua` 主管道；各 AI |
| `init` / `finally` | 地牢主管道；每只怪 AI（含萨满召唤物 cleanup） |
| `fx.wait` | 旅途、AI 风摇/冷却、读条、伏击延时 |
| `fx.wait_event` | `mob_attack` / `boss_interrupt` / `player_slash` |
| `fx.when_all` | 双怪并行战斗 |
| `fx.when_any` | 接招 vs 挥砍；萨满读条；刺客伏击 |
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
| `world.lua` | 世界状态、日志、生成/摧毁（`kind` + `ai`） |
| `ai.lua` | 怪物 AI Cont（basic / berserker / shaman / assassin） |
| `combat.lua` | 战斗 / 宝箱 / Boss（含 `player_slash` 事件） |

默认数值调成 **必胜**；`opts.assert=true` 时检查 pause、finally、宝箱并行、Boss 路径、复杂 AI 标志、通关。
