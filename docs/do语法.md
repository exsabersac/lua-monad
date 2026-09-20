# do-notation 语法（`@mdo`）

本库用**预处理器**把类 Haskell 的 do 语法展开成 `>>` / `..` 嵌套，而不是运行时 table DSL。源文件可用 `*.mdo`，编译后得到普通 `*.lua`。

## 快速上手

```bash
# 在仓库根目录
lua tools/mdo.lua examples/do_maybe_foo.mdo          # → examples/do_maybe_foo.lua
lua tools/mdo.lua examples/foo.mdo -o /tmp/foo.lua   # 指定输出

lua examples/do_maybe_foo.lua
```

库 API（`src/mdo.lua`）：

| 函数 | 说明 |
|------|------|
| `mdo.expand(body, monad)` | 展开 `@mdo`/`@end` 之间的正文 → Lua 表达式字符串 |
| `mdo.preprocess(src)` | 处理整文件，替换所有 `@mdo … @end` |

`monad` 参数目前主要用于校验与文档上下文；真正的绑定靠 monadic **值**上的 `>>` / `..`（见 `monad.makeMonad` 元表糖），因此 EXPR 里请写完整调用（如 `Maybe.Just(3)`）。

## 块语法

```
前缀 = @mdo MONAD
  语句…
@end
```

- `MONAD`：Lua 标识符或简单限定名（如 `Maybe`）；展开不强制调用 `MONAD.bind`。
- 块可出现在赋值右侧：`local foo = @mdo Maybe … @end`。
- 块外普通 Lua **原样保留**。

### 块内语句

| 形式 | 含义 | 展开要点 |
|------|------|----------|
| `NAME <- EXPR` | 绑定（Haskell `<-`） | `EXPR >> function(NAME) return … end` |
| `_ <- EXPR` | 绑定并丢弃 | 同裸表达式序列：`EXPR .. (…)` |
| `let NAME = EXPR` | 纯 let | `(function() local NAME = EXPR; return … end)()` |
| 裸 `EXPR`（非末行） | 序列、丢弃结果（Haskell `>>`） | `(EXPR .. (…))` |
| 裸 `EXPR`（末行） | 整个 do 的结果 | 原样作为最内层表达式 |

允许空行与整行 `--` 注释；行尾 `--` 注释会被去掉（字符串内含 `--` 的同行写法请避免）。

### 展开示例

源：

```
local foo = @mdo Maybe
  x <- Maybe.Just(3)
  y <- Maybe.Just("!")
  Maybe.Just(tostring(x) .. y)
@end
```

生成：

```lua
local foo = Maybe.Just(3) >> function(x)
return Maybe.Just("!") >> function(y)
return Maybe.Just(tostring(x) .. y)
end
end
```

中间丢弃：

```
@mdo Maybe
  Maybe.Just(1)
  x <- Maybe.Just(2)
  Maybe.Just(x)
@end
```

→ `(Maybe.Just(1) .. (Maybe.Just(2) >> function(x) return Maybe.Just(x) end))`

## 示例文件

| 文件 | 内容 |
|------|------|
| `examples/do_maybe_foo.mdo` | LYAH `foo`：`Just "3!"` |
| `examples/do_walk_the_line.mdo` | 走钢丝 routine → `Just (3,2)` |

仓库同时提交生成的 `.lua`；改 `.mdo` 后请重新跑 `tools/mdo.lua`。

## 限制（当前版本）

1. **EXPR 必须单行**（不做完整 Lua 解析）。
2. **无模式匹配失败**（不像 Haskell 的 `Just x <- …` 失败进 fail）。
3. **暂不支持嵌套 `@mdo`**（块内再写 `@mdo` 会报错）。
4. **最后一行**必须是裸 monadic 表达式，不能是 `let` 或 `NAME <- …`。
5. `NAME` 须为 Lua 标识符；绑定依赖值上已有 `>>` / `..` 元方法。
6. 行尾注释剥离对字符串内 `--` 做了简单处理，复杂同行字符串请拆行。

## 报错

解析失败会打印带**行号**的中文信息，例如：

```
mdo: 第 19 行: do 块最后一行须为 monadic 表达式（不能是 NAME <- EXPR）
```
