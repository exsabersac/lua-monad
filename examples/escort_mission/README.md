# 护卫任务（Escort Mission）

相对完整的 **headless / 确定性** 演示：护送商队穿越三检查点，用 Cont + withEnv + fx + GameSim 串起车道并行、代理挂接、信道通报、监督重启与救援超时窗。

## 如何运行

```bash
# 仓库根目录
lua examples/escort_mission/main.lua          # 中文战报 + 通关
lua examples/escort_mission/main.lua test     # 安静自检
lua tests/run.lua                             # 含本 demo 的 smoke
```

编程入口：

```lua
package.path = "src/?.lua;examples/escort_mission/?.lua;" .. package.path
local EscortMission = require("escort")
local r = EscortMission.run({ quiet = true, assert = true })
assert(r.victory)
```

## 剧情结构

1. **双车道 `fx.lane`**：`escort` 按检查点移动；`combat` 在河湾遭遇伏击并清怪
2. **`fx.proxy("escort")`**：HUD 旁路 `proxy_join`，不拥有护卫 Cont，只等车道结束
3. **`fx.chan`**：检查点到达通知（cap=3）+ 伤害警报（cap=1）
4. **`fx.supervise`**：山贼斥候首次突袭 Failed，`max_restarts=1` 后恢复进攻
5. **中途 `set_paused`**：前往「河湾」时验证 pause 冻结游戏时间
6. **`with_timeout` 救援窗**：抵达河湾后限时等待 `ambush_cleared`
7. **destroy → finally**：击杀伏击怪后 AI `finally` 清理标志

## 特性对照表

| 能力 | 本 demo 何处 |
|------|----------------|
| `fx.lane` / `join_handles` | escort + combat 双车道 |
| `fx.proxy` / `proxy_join` | HUD 挂接 escort |
| `fx.chan` / `send` / `recv` / `close` | 检查点 / 伤害警报 |
| `fx.supervise` | 伏击 AI 首次失败后重启 |
| `fx.with_timeout` | 河湾救援窗口 |
| `GameSim` pause / destroy / emit | 全程 |
| `sim:register` 异步 `anim` | 玩家挥砍 |

## 模块

| 文件 | 职责 |
|------|------|
| `main.lua` | 可执行入口、叙事打印 |
| `escort.lua` | `EscortMission.run` |
| `escort_world.lua` | 世界状态、日志、生成/摧毁 |

默认数值调成 **必胜**；`opts.assert=true` 时检查 pause、finally、lanes、proxy、chan、supervise、rescue、通关。
