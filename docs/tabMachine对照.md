# Cont/fx ↔ tabMachine 对照

目标：**对齐有用的 tabMachine 能力子集**，不是完整克隆。  
参考概念来自 ThinEureka/tabMachine（abort/stop、iquit、seq、suspend、join/select）。  
版本：**0.2.3-eng**。

图例：✅ 已对齐　🔶 部分／语义近似　❌ 本轮有意不做

---

## 功能映射

| tabMachine 概念 | Cont / fx | 状态 | 说明 |
|-----------------|-----------|------|------|
| `stop` | `fx.stop` / `Coro.Stopped` | ✅ | 合作式停止；不调后续续延 |
| `abort` | `fx.abort` / `Coro.Aborted` | ✅ | 异常中止；**join/when_all 不算成功值**，向 waiter 传播 `Aborted` |
| cancel / 外部停 | `flow.cancel` / `Coro.force_stop` | ✅ | 仍为 **Stopped**（取消语义）；经 `Yielded.abort` 跑 iquit→finally |
| `iquit` | 固定名 `iquit`/`__iquit__`、`__IQuit__`；`Cont.with_iquit` / `Cont.iquit_finally` | ✅ | 仅 Stopped/Aborted/Failed/cancel；**先于** finally；成功 Done **跳过** |
| `final` / finally | `finally`/`__final__`、`__Finally__`；`Cont.finally` | ✅ | Done/Stopped/Aborted/Failed/cancel 皆跑 |
| `..` / `g_t.seq` | `fx.seq(mas)` | ✅ | 左→右 `>>`，返回最后值；空 → `unit(nil)` |
| `join` | `fx.join` / `fx.join_handles` | ✅ | 子 Done→值；Failed/Stopped/**Aborted** 传播（abort≠成功） |
| `select` / 竞速 | `fx.when_any` | ✅ | 第一 Done 胜出；其余 cancel |
| `join` 全员 | `fx.when_all` | ✅ | 全 Done 才成功；任一 fail/stop/abort 失败 |
| `cancel_siblings` | `opts.cancel_siblings` on join | ✅ | **仅 join 成功后**取消同父未纳入集合的兄弟；若兄弟先 abort/stop，waiter 先失败 |
| suspend / resume | `flow:suspend()` / `flow:resume()`；`GameSim:suspend_flow` / `resume_flow` | ✅ | 按 flow 冻结 wait/timer/poll 兑现；≠ 全局 `GameSim:set_paused` |
| 多行 `s`/`t` 标签机 | — | ❌ | 不引入 tab 代理语法；用 `withEnv` 步骤名 + `fx.seq` |
| `tabProxy` | — | ❌ | 无代理对象模型 |
| `xx_update` 为标签 | — | ❌ | 无每帧标签调度；用 `fx.wait_until` / `schedule_poll` |
| notify / 邮箱协作 | `fx.chan` / `send` / `recv` | ✅ | 有界 mailbox；默认容量 1；非 tab 事件 DSL |
| 完整 tab 树 DSL | — | ❌ | 保持 Cont/CPS；文档映射即可 |

---

## stop vs abort（务必分清）

| | `fx.stop` | `fx.abort` | `flow.cancel` / `force_stop` |
|--|-----------|------------|------------------------------|
| Answer | `Stopped` | `Aborted` | `Stopped` |
| join / when_all | 非成功，传播 stopped | 非成功，传播 **aborted** | 非成功，stopped |
| iquit | 跑 | 跑 | 跑 |
| finally | 跑 | 跑 | 跑 |

**fork 子任务 `abort`：父 `join` 得到 `aborted`，绝不当成成功值。**  
`opts.cancel_siblings` 只在 join **成功**路径触发；与 abort 无「成功后取消」交互。

---

## iquit vs finally

```text
成功 Done:     (跳过 iquit) → finally
stop/abort/fail/cancel:  iquit → finally
```

嵌套：`Cont.iquit_finally(ma, iquit, finally)` ≡ 内 `with_iquit`、外 `with_finally`，保证 cancel 时顺序。

---

## 有意推迟（非缺陷清单）

- 多行 `s`/`t`、tabProxy、`xx_update` 标签语义  
- 完整 tabMachine 事件/UI 绑定 DSL  
- 监督重启（见工程可用验收 P2；channel 已在 0.2.6-eng 落地）


## 性能粗测

```bash
lua5.3 tools/bench_cont_fx.lua
lua5.3 tools/trace_dump.lua
```

热路径分配主要来自 Cont 代理与 `>>` 闭包；优先复用 session、缩短管道。
`0.2.5-eng`：Cont 热路径 + **fx.run 无 Yield 同步快路径**；粗测见 [`性能与工具.md`](性能与工具.md)。工具入口 [`tools/README.md`](../tools/README.md)。
