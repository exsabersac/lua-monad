# Unity 宿主模板（stub）

把 Cont/fx 接到 Unity 时的**最小拷贝包**，不是完整 Unity 工程。

设计说明见仓库 [`docs/Unity对接.md`](../../docs/Unity对接.md)。

## 文件

| 文件 | 作用 |
|------|------|
| `LuaGameScheduler.lua` | 薄适配：把注入的 `host.now/schedule/cancel` 变成 session 认的 Scheduler |
| `UnityGameScheduler.cs.txt` | C# **模板**（扩展名 `.txt` 以免误编译）；改名为 `.cs` 后挂到场景物体上 |
| `MockUnityHost.lua` | 无 Unity 时用 VirtualClock / GameSim 假装 host，演示适配形状 |

## 拷进 Unity 工程

1. 复制本仓库 `src/` 到工程的 Lua 目录（或加入 `package.path` / xLua build）。  
2. 复制本目录下 `LuaGameScheduler.lua`。  
3. 将 `UnityGameScheduler.cs.txt` 复制为 `Assets/.../UnityGameScheduler.cs`，按所用 Lua 宿主（xLua / tolua / slua）补全「调用 Lua 函数」的几处 TODO。  
4. 场景中挂 `UnityGameScheduler`；在 Lua 启动处：

```lua
package.path = "..../src/?.lua;..../host/unity/?.lua;" .. package.path

local LuaGameScheduler = require("LuaGameScheduler")
-- host 由 C# 注入全局，或在此组装：
-- host = { now = ..., schedule = ..., cancel = ... }
local scheduler = LuaGameScheduler.adapt(host)

local fx = require("fx")
local Cont = require("cont")
-- fx.run(ma, handlers, { scheduler = scheduler })
-- 或 fx_sched.start_session(ma, handlers, { scheduler = scheduler })
```

5. 实体 `OnDestroy` → 取消对应 flow（见 Unity对接文档）。  
6. 无 Unity 验证适配形状：

```bash
# 仓库根目录
lua5.3 -e 'package.path="src/?.lua;host/unity/?.lua;"..package.path
  local Mock = require("MockUnityHost")
  local host, pump = Mock.with_virtual()
  local S = require("LuaGameScheduler").adapt(host)
  local h = S.schedule(0.5, function() print("due@"..S.now()) end)
  pump(0.5)
'
```

或使用完整参考宿主：`lua5.3 examples/game_sim_flow.lua` / `examples/dungeon_raid/main.lua`。

## 注意

- 推荐 **scaled** 游戏时间（随 `Time.timeScale`）；暂停 = `timeScale=0`。  
- Lua resume **必须在主线程**。  
- 本目录不包含 xLua/tolua 插件本身。
