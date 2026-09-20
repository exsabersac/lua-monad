# 顺序 do（`runDo` / `perform`，原生 coroutine）

本机制让你在 **普通 Lua 函数**里按顺序写「先取 monadic 值，再继续」，**不必手写 `>>` 嵌套**；底层仍由该 monad 的 **`bind`** 驱动。

实现细节：用 **Lua 原生 `coroutine`** 挂起/恢复用户 body。这与 Cont CPS 协程（`src/coro.lua` 的 `Coro.yield`）**无关、不要混用文档心智**：

| | `@mdo` 预处理 | `runDo` / `perform` | Cont `Coro` |
|--|---------------|---------------------|-------------|
| 用户写法 | `.mdo` 里 `x <- ma` | `local x = perform(ma)` | `Coro.yield` + Cont bind |
| 何时变成 bind | 编译期展开成 `>>` | **运行时** `bind(ma, step)` | Cont 的 CPS bind |
| 协程 | 无 | **原生** `coroutine`（仅实现细节） | **无**原生协程；续延模拟 |
| 末行 | 裸 monadic 表达式 | `return` monadic 值 | Cont 计算 |

详见对照：[`do语法.md`](do语法.md)（`@mdo`）、[`CPS设计与原理.md`](CPS设计与原理.md)（Cont Coro）。

## 快速上手

```bash
# 仓库根目录
lua examples/do_coro_maybe_foo.lua       # Just "3!"
lua examples/do_coro_walk_the_line.lua   # Just (3,2)
```

```lua
package.path = "src/?.lua;" .. package.path
local Maybe = require("maybe")
local perform = require("do_coro").perform

local foo = Maybe.runDo(function()
  local x = perform(Maybe.Just(3))
  local y = perform(Maybe.Just("!"))
  return Maybe.Just(tostring(x) .. y)   -- 末行 return monadic 值
end)
-- foo == Just "3!"
```

也可用模块无关入口：

```lua
local do_coro = require("do_coro")
local r = do_coro.runDo(Maybe, function()
  local a = do_coro.perform(Maybe.Just(1))
  return Maybe.Just(a + 1)
end)
-- 或传入 bind 函数：do_coro.runDo(Maybe.bind, body)
```

已挂薄包装的模块：`Maybe` / `List` / `Identity` / `Status` / `Reader` / `Writer`（含 `WriterList`）的 `M.runDo(body)`。其它 monad 用 `do_coro.runDo(M, body)` 或 `do_coro.attach(M)`。

## API（`src/do_coro.lua`）

| 函数 | 说明 |
|------|------|
| `perform(ma)` | **仅**在 `runDo` 的 body 内合法：`coroutine.yield(ma)`；恢复得到裸值 `a` |
| `runDo(M, body)` | `M` 为带 `.bind` 的模块；或 `runDo(bind, body)` |
| `attach(M)` / `install(M)` | 设置 `M.runDo = function(body) return runDo(M, body) end` |

### 驱动逻辑（经典模式）

```lua
local function runDo(bind, body)
  local co = coroutine.create(body)
  local function step(x)
    local ok, y = coroutine.resume(co, x)
    if not ok then error(y) end
    if coroutine.status(co) == "dead" then
      return y  -- body 返回的最终 monadic 值
    end
    return bind(y, step)  -- y 是 ma
  end
  return step()  -- 首次无参；body 通常以 perform 开头
end
```

1. `resume` body；
2. 若 `perform(ma)` → yield 出 `ma`，则 `bind(ma, step)`，在续函数里 `resume(co, a)`；
3. body **return** 的 monadic 值在协程 `dead` 时作为整个 `runDo` 的结果。

在 `runDo` **之外**调用 `perform` 会报错：`perform: only valid inside runDo`。

## 与 `@mdo` 怎么选？

- 想要类 Haskell 源码外观、可检入 `.mdo` → **`@mdo`**。
- 想在普通 `.lua` 里顺序书写、调试栈更直观、不依赖预处理器 → **`runDo`/`perform`**。
- 二者语义都应对齐「do + bind」；本库示例对 Maybe 的 foo / walk routine 结果一致。

## 限制

- **List 等多结果 / 分支 bind**：单条原生 coroutine 不能克隆分叉；`List.runDo` 仅适合教学上「碰巧只走一条」的写法，非确定性请用手写 `>>` 或其它策略。
- body 内不要再套一层会 yield 给 `runDo` 驱动器以外的原生协程协议。
- `perform` 得到的是 **解包后的 `a`**，不是 `ma`；末行请 `return` 完整的 monadic 值（或对「已是 ma 的表达式」直接 return，如 `return landLeft(1)(second)`）。

## 命名说明

使用 **`perform`** 而非 `yield`，以免与：

- `coroutine.yield`（实现细节），
- `Coro.yield`（Cont CPS 协程 API）

在文档与代码检索中撞名。
