# fx 分层：Core 与 Sugar

版本 **0.2.20-eng**。公共 API **全部保留**；本页只划「推荐心智」与「可选糖衣」，便于少记名字、不破坏既有示例（escort / worker / dungeon）。

> 无 Tab DSL。实现见 [`src/fx.lua`](../src/fx.lua)；调度见 [`核心整理说明.md`](核心整理说明.md)。

## 两层一览

| 层 | 用途 | 建议 |
|----|------|------|
| **Core** | 业务主线：等待、终态、fork/join、when_*、chan、超时、监督、运行 | **优先学、优先写** |
| **Sugar** | 命名 lane、proxy、有限并发池、演示 connect/click、别名、墙钟 wait_real | 需要时再开；可全用 Core 等价表达 |

## Core（推荐心智）

| 能力 | API |
|------|-----|
| 等待 | `wait` / `wait_event` / `wait_until` |
| 终态 | `stop` / `abort` / `fail` |
| 非结构化并发 | `fork` + `join` / `join_handles` |
| 结构化并行 | `when_all` / `when_any` |
| Channel | `chan` + `send` / `recv` / `close`（及 `is_closed`） |
| 超时 / 监督 | `with_timeout` / `supervise` |
| 注册效果 | `register` / `unregister` |
| 运行 | `run`；session 入口 `fx.sched.start_session`（或 `fx.flow`） |
| 资源 / 追踪 | `with_resource`（`bracket` 别名）/ `set_tracer` |

## Sugar（可选）

| 能力 | API | 与 Core 关系 |
|------|-----|--------------|
| 命名子流 | `lane` / `lane_join` / `lane_stop` / `lane_abort` / `lanes` | **lane ≈ 命名 fork**；`lanes` ≈ 命名版 `when_all` |
| 外部引用 | `proxy` / `proxy_join` / `proxy_stop` / `proxy_abort`（+ `flow:proxy`） | **proxy ≈ 外部 ref**（指向 lane 名 / handle / flow），不拥有 Cont |
| 有限并发 | `map_parallel` / `for_each_parallel` | 滑动窗口 `fork`+`join` |
| 顺序 | `seq` | `Cont.chain` 串联 |
| 别名 | `spawn`=`fork`；`join_all`/`join_any`=`when_*`；`throw`=`fail` | 纯别名 |
| 演示效果 | `connect` / `click` | 教学 mock；工程请 `register` 真实 kind |
| 墙钟 | `wait_real` | **opt-in**；游戏逻辑用 `wait` + 游戏时间 scheduler |
| 顶层便利 | `run_all` / `run_any` / `try` | `run_parallel` / `run` 薄包装 |

## 重叠关系（怎么选）

```text
when_all(mas)     ≈  fork 各 ma 再 join_handles
lanes(name→ma)    ≈  按名 lane 启动再 join_handles（结果字典）
lane(name, ma)    ≈  fork(ma)，另登记 session.lanes[name]
proxy(target)     ≈  不启动任务，只持有对已有 lane/handle/flow 的引用
```

选路建议：

1. **只要并行汇合** → `when_all` / `when_any`（或 `fork`+`join` 中间还要做事时）。
2. **要按名字停/查子流**（对照 tabMachine `c:start("t1")`）→ `lane*`；仍可用 `fork`+自己管表。
3. **外部模块要 wait/stop 别人的流、又不拥有 Cont** → `proxy*`。
4. **有界工人池** → Core `chan`；或 Sugar `map_parallel`（固定并发、按输入序）。

## 文档入口

- API 表：[`API.md`](API.md)（fx 节注明 Core/Sugar）
- 异步写法：[`异步效果同步写法.md`](异步效果同步写法.md)
- 版本：[`版本与路线.md`](版本与路线.md) · [`CHANGELOG.md`](../CHANGELOG.md)
