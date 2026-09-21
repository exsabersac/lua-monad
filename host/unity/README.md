# Unity 宿主模板（stub）

把 Cont/fx 接到 Unity 时的**最小拷贝包**，不是完整 Unity 工程。

设计说明见仓库 [`docs/Unity对接.md`](../../docs/Unity对接.md)。

## 文件

| 文件 | 作用 |
|------|------|
| `LuaGameScheduler.lua` | 薄适配：把注入的 `host.now/schedule/cancel[/schedule_real]` 变成 session 认的 Scheduler |
| `FxUnityBootstrap.lua` | 一键接线：`bootstrap(host)` → `api.scheduler` + `api.run`（自动填 `opts.scheduler`） |
| `UnityGameScheduler.cs.txt` | C# **模板**（扩展名 `.txt` 以免误编译）；改名为 `.cs` 后挂到场景物体上 |
| `MockUnityHost.lua` | 无 Unity 时用 VirtualClock / GameSim 假装 host，演示适配形状 |

## 拷贝清单（copy-paste）

按顺序做完即可在 xLua 工程里跑通 `fx.wait`（scaled 游戏时间）。

### 1. 拷贝 Lua

```text
仓库 src/          →  工程 Lua 目录（或加入 package.path / xLua build）
host/unity/*.lua   →  同上（至少 LuaGameScheduler.lua + FxUnityBootstrap.lua）
```

### 2. 拷贝并改名 C#

```text
UnityGameScheduler.cs.txt  →  Assets/.../UnityGameScheduler.cs
```

- 场景常驻物体挂 `UnityGameScheduler`（`DontDestroyOnLoad`）。
- 打开文件内 **TODO(xLua)**：`InjectIntoLua`、`InvokeLuaCallback` 换成真实 `LuaFunction` 调用。

### 3. C# 启动时注入 host

在 LuaEnv 就绪后调用（示意）：

```csharp
// luaenv 为你的 XLua.LuaEnv
UnityGameScheduler.Instance.InjectIntoLua(/* luaenv */);
```

注入结果：全局 `UnityHost = { now, schedule, cancel [, schedule_real] }`。

### 4. Lua 启动 flow（推荐 Bootstrap）

```lua
package.path = "..../src/?.lua;..../host/unity/?.lua;" .. package.path

local Boot = require("FxUnityBootstrap")
local api = Boot.from_global("UnityHost")  -- 或 Boot.bootstrap(host)

local Cont = require("cont")
local fx = require("fx")

-- 自动带 opts.scheduler；业务继续用 fx.wait（游戏时间）
local flow_ma = fx.wait(0.5) >> function(_)
  return Cont.unit("ready")
end
local result = api.run(flow_ma)

-- 手动写法（等价）：
-- local sched = require("LuaGameScheduler").adapt(UnityHost)
-- fx.run(flow_ma, nil, { scheduler = sched })
```

### 5. 实体销毁

`OnDestroy` → 对该实体绑定的 `flow.cancel()`（见 [`docs/Unity对接.md`](../../docs/Unity对接.md) / `fx.bind_entity`）。

### 6. 墙钟 `fx.wait_real`（可选，默认禁用）

- **游戏逻辑请继续用 `fx.wait`**（scaled）。
- 仅网络/SDK 等需要墙钟时：
  1. C# 注入 `UnityHost.schedule_real`（模板已提供 `ScheduleLuaReal`）；
  2. 或单测/演示：`api.run(ma, nil, { allow_real_time = true })`（busy_wait，勿用于战斗逻辑）。
- 无 `schedule_real` 且未开 `allow_real_time` → **Failed** `{ tag = "wait_real_unsupported" }`（清晰失败，不静默）。

### 7. 无 Unity 本地冒烟

```bash
# 仓库根目录
lua5.3 -e 'package.path="src/?.lua;host/unity/?.lua;"..package.path
  local Mock = require("MockUnityHost")
  local host, pump = Mock.with_virtual()
  local api = require("FxUnityBootstrap").bootstrap(host)
  local fired = false
  api.scheduler.schedule(0.5, function() fired = true end)
  pump(0.5)
  assert(fired)
  print("bootstrap ok @", api.scheduler.now())
'
```

或：`lua5.3 examples/game_sim_flow.lua` / `examples/dungeon_raid/main.lua`。

## 注意

- 推荐 **scaled** 游戏时间（随 `Time.timeScale`）；暂停 = `timeScale=0`。  
- Lua resume **必须在主线程**（模板用 Update 出队）。  
- 本目录不包含 xLua/tolua 插件本身。
