# Cont / fx 对接 Unity（Lua 5.3）

目标：把本仓库的 **Cont + fx session 调度器**接到 Unity 主循环上，用**游戏时间**驱动 `fx.wait` / 超时，并在实体销毁时干净取消流程。

不绑定具体 Lua 宿主（xLua / tolua / slua 均可；它们通常是 **Lua 5.3**）。本仓库已在 **Lua 5.3.6** 下跑通 `tests/run.lua`，详见 [Lua53兼容性.md](Lua53兼容性.md)。

分层总览见 [工程对接与后续.md](工程对接与后续.md)。本文只写 **Unity 侧怎么接**。

---

## 1. 保留什么、换什么

| 层 | 做法 |
|----|------|
| Session（`fx_sched` / `start_session`） | **保留**：Done/Yielded、fork/join、when_all/any、取消树、`finally` |
| 游戏时间 Scheduler | **换实现**：Unity 定时器（见下）实现 `now` / `schedule` / `cancel` |
| 效果 handler | **注册**到 Unity（动画、等待秒数等），不要在 Lua 里 `Thread.Sleep` |

业务 Cont 代码**不**直接碰 `MonoBehaviour`；只通过 Scheduler 接口与注册的 `kind` 间接调用引擎。

参考宿主（无 Unity、可本地跑）：[`src/game_sim.lua`](../src/game_sim.lua)。  
综合叙事校验：[`examples/dungeon_raid/`](../examples/dungeon_raid/)（地牢突袭）。  
拷贝用模板：[`host/unity/`](../host/unity/)。

---

## 2. 游戏时间 Scheduler（推荐 scaled）

Session 期望的鸭子接口（与 `src/scheduler.lua` 一致）：

```text
now()                 → number   -- 当前游戏时间（逻辑秒）
schedule(delay, cb)   → handle   -- 再过 delay 秒后回调
cancel(handle)        →          -- 取消；迟到回调必须忽略
```

### 2.1 用 scaled game time（推荐）

| | scaled（`Time.time` / `WaitForSeconds` / `Invoke`） | unscaled（`Time.unscaledTime` / `WaitForSecondsRealtime`） |
|--|--|--|
| `Time.timeScale = 0`（暂停） | 定时器**不推进**，已挂起的 `wait` 不唤醒 | 仍推进 |
| 慢放 / 加速 | 与战斗节奏一致 | 与 UI/加载更一致 |

**推荐业务 wait / 技能读条 / AI 冷却走 scaled 游戏时间**，这样暂停菜单设 `timeScale=0` 时，Cont 流程自然冻结；`cancel`（切场景、毁实体）仍应**立即**清 timer，与是否暂停无关。

墙钟 / realtime 仅留给 SDK、网络超时等少数场景（工程对接文档列为 P2，默认业务禁用）。

### 2.2 Lua 薄适配

`host/unity/LuaGameScheduler.lua` 只做一层：把注入的 `host.now` / `host.schedule` / `host.cancel` 暴露成 session 认的 Scheduler。C# 或 Mock 负责真正计时。

### 2.3 C# 模板要点

见 `host/unity/UnityGameScheduler.cs.txt`：

- `MonoBehaviour` + **scaled** 协程（`WaitForSeconds`）或等价 `Invoke`
- 到期后把「调用 Lua 续延」**投递到主线程队列**，在 `Update` 里统一执行（避免在非主线程碰 Unity API / Lua 状态）
- `Pause` = `Time.timeScale = 0`；不必在 Scheduler 里再维护一套 pause 标志（若宿主自己驱动 `tick`，则另论，见 GameSim）

---

## 3. 桥接模式：C# 调度 → 主线程 Lua resume

```text
业务 Cont / fx.wait
        │ Yielded{kind=wait}
        ▼
  fx_sched（session）
        │ scheduler.schedule(delay, cb)
        ▼
  LuaGameScheduler  →  host.schedule（C#）
        │
        ▼
  Unity 定时器（scaled）到期
        │
        ▼
  入队「调用 cb / 推进 session」  ──►  主线程 Update 出队执行
        │
        ▼
  Lua resume（同一 Lua state，主线程）
```

约定：

1. **Session 推进只发生在主线程**（允许碰游戏对象 / 同一 Lua VM 的上下文）。
2. 若 timer 回调已在主线程（常见），仍可先入队再 `Update` 执行，避免在 timer 深层嵌套里同步跑长 Cont。
3. `cancel(handle)` 必须拆掉 timer，并令迟到入队的回调 **no-op**（handle 上 `cancelled` 标志，与 GameSim / VirtualClock 一致）。

---

## 4. 实体销毁 → 取消 flow

| Unity | Cont/fx |
|-------|---------|
| `MonoBehaviour.OnDestroy` / 实体回收 | 对该实体绑定的 session 调用 `flow.cancel()`（或宿主封装的 `CancelFlows(entity)`） |
| 切场景 | 取消场景内未完成 flow；或白名单「跨场景保留」 |

映射方式（任选）：

- 每个挂流程的实体组件持有 `flow` 句柄列表；`OnDestroy` 里逐个 `cancel`
- 或维护 `entityId → flows`，销毁时统一取消（对齐 GameSim 的 `destroy_entity`）

不变量：cancel 后清 timer；`finally` / init 清理仍走；**已 cancel 的 wait 不得被迟到回调 resume**。

---

## 5. 效果注册表（Unity kinds）

业务只 `Coro.yield({ kind = "...", ... })` 或使用 `fx.wait` 等已有助手；引擎侧注册 handler。

建议起步 kinds：

| kind | 行为 | 说明 |
|------|------|------|
| （内置）`wait` | 走 Scheduler，不在 handler 里睡 | session 已支持 `opts.scheduler` |
| `PlayAnimation` | 播 Animator / DOTween；完成后 `resume` | 建议 `async` |
| `WaitForSeconds` | 若不用内置 wait，可薄封装为走同一 Scheduler | 避免双套时间 |

注册形态对齐 GameSim：

```lua
-- 伪代码：宿主提供 register(kind, handler, { async = true })
host.register("PlayAnimation", function(req, resume)
  -- C#：Play(req.name)，结束时主线程 resume({ ok = true })
end, { async = true })
```

瞬时 fire-and-forget（如 SFX）可同步 handler；需要「播完再往下」的一律 async + resume。

---

## 6. 推荐 Lua 宿主（不强制）

| 宿主 | 备注 |
|------|------|
| **xLua** | 常见于 Unity；Lua **5.3**；C# 调 Lua / Lua 调 C# 成熟 |
| **tolua** / **tolua#** | 同样多为 5.3 |
| **slua** | 同上 |

本仓库**不**要求某一种；只要能：

1. 把 `src/` 加入 `package.path`（或等价加载）
2. 在主线程执行 Lua
3. 从 C# 注入 `host.now` / `schedule` / `cancel`（或等价绑定）

---

## 7. 最小集成步骤清单

1. 将本仓库 `src/`（至少 `monad`/`cont`/`cont_env`/`coro`/`fx`/`fx_sched`/`scheduler`）拷入工程 Lua 搜索路径。  
2. 拷贝 `host/unity/LuaGameScheduler.lua`；按宿主方式把 C# 的 `UnityGameScheduler`（由 `.cs.txt` 改名实现）注入为 `host`。  
3. 启动 flow 时传入 `opts.scheduler = LuaGameScheduler.adapt(host)`（或直接把 adapt 结果交给 `fx.run` / `start_session`）。  
4. 注册 Unity kinds（`PlayAnimation` 等）；业务继续用 `Cont.withEnv` + `fx.*`。  
5. 实体组件 `OnDestroy` → `flow.cancel()`；验证暂停（`timeScale=0`）时 wait 不醒、恢复后续跑。  
6. 本地无 Unity 时：用 `host/unity/MockUnityHost.lua` 或直接跑 `GameSim` / `examples/dungeon_raid` 校验语义。  
7. 回归：`lua5.3 tests/run.lua`（见兼容性说明）。

---

## 8. 参考与示例

| 资源 | 用途 |
|------|------|
| [`src/game_sim.lua`](../src/game_sim.lua) | 参考宿主：schedule / pause / wait_event / 实体销毁 / `register` |
| [`src/scheduler.lua`](../src/scheduler.lua) | Scheduler 接口 + `VirtualClock` |
| [`examples/game_sim_flow.lua`](../examples/game_sim_flow.lua) | wait + pause、事件、实体 finally |
| [`examples/dungeon_raid/`](../examples/dungeon_raid/) | 综合 showcase（通关叙事 + 复杂 AI） |
| [`host/unity/`](../host/unity/) | Unity 拷贝模板 + Mock |

---

## 9. 修订记录

| 日期 | 说明 |
|------|------|
| 2026-09-21 | 初稿：scaled 游戏时间、主线程桥接、实体销毁、效果注册、xLua/tolua/slua、清单与 GameSim/dungeon_raid 指向 |

## FrameScheduler / wait_until（弱 timer 备选）

若 Unity 侧已有可靠 scaled timer，优先 `LuaGameScheduler.adapt(host)`。  
若只有 `Update(dt)`、timer 不可靠，可用 `require("scheduler").FrameScheduler()`：

- `tick(dt)`：推进游戏时间、触发到期 `schedule`、poll `wait_until`
- 业务：`fx.wait_until(pred, { interval = 0 })`
- `GameSim` 同样实现 `schedule_poll`，单测/离线可互换

