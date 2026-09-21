# Lua 5.3 兼容性说明

## 结论

本仓库 Cont / fx / GameSim / dungeon_raid 主线以 **Lua 5.3+** 为目标（Unity 上 xLua / tolua / slua 多为 5.3）。  
已在本机用 **Lua 5.3.6** 跑通完整测试：

```bash
# 仓库根目录
lua5.3 tests/run.lua
```

期望输出末尾：`All tests passed.`

## 符号糖 `>>`（bind）

Haskell 风格的 `ma >> f` 依赖元方法 **`__shr`**（Lua 5.3 起对 `>>` 的元方法）。  
实现见 [`src/monad.lua`](../src/monad.lua)：

```lua
mt.__shr = function(ma, f)
  return m.bind(ma, f)
end
```

Lua 5.2 及更早**没有** `__shr`，不能依赖该写法。Lua 5.4 同样支持 `__shr`，可继续使用。

顺序组合（丢弃左结果）用 `ma .. mb`（`__concat`），与版本无关。

## 刻意避开的 5.4-only 特性

库代码与示例**不依赖**例如：

- 常量属性表（`<const>`）/ to-be-closed（`<close>`）
- 5.4 新增的库细节或行为变更作为前提

业务工程若混用 5.4 特性，请自行保证目标宿主（Unity 5.3）可加载。

## 如何用 lua5.3 跑测试与示例

```bash
cd /path/to/lua-monad

lua5.3 tests/run.lua

lua5.3 examples/game_sim_flow.lua
lua5.3 examples/dungeon_raid/main.lua
lua5.3 examples/fx_wait_click_flow.lua
```

系统若只有 `lua` 指向 5.4，请显式调用 `lua5.3`，或确认 `lua -v` 为 5.3.x。

## 修订记录

| 日期 | 说明 |
|------|------|
| 2026-09-21 | 初稿：5.3.6 验证、`__shr`、避免 5.4-only、运行方式 |
