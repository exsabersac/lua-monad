# bench_summary

生成自 `tools/bench_summary.lua`（Lua 5.3，15 用例）。

| name | n | sec | rate (/s) | kb_delta |
|------|--:|----:|----------:|---------:|
| Cont >> chain | 20000 | 0.0263 | 761673 | 6554.6 |
| Cont.map chain | 20000 | 0.0102 | 1.95e+06 | 4450.0 |
| Cont.chain | 20000 | 0.0223 | 898634 | 6081.0 |
| Cont .. chain | 20000 | 0.0213 | 937603 | 6081.4 |
| Coro.start unit | 20000 | 0.0167 | 1.20e+06 | 248.1 |
| fx.seq×3 run | 20000 | 0.1444 | 138469 | 938.3 |
| fx.seq×3 eval | 20000 | 0.0594 | 336887 | 682.3 |
| session wait(0) _(N=5000)_ | 5000 | 0.1268 | 39441 | 930.7 |
| fx.lane+join _(N=2000)_ | 2000 | 0.3722 | 5374 | 1073.6 |
| fx.proxy_join _(N=2000)_ | 2000 | 0.3964 | 5045 | 400.9 |
| fx.chan VC _(N=5000)_ | 5000 | 0.1804 | 27722 | 487.5 |
| fx.chan GameSim _(N=2000)_ | 2000 | 0.0745 | 26833 | 697.4 |
| fx.supervise _(N=5000)_ | 5000 | 1.0017 | 4991 | 1170.2 |
| fx.wait_until triv _(N=5000)_ | 5000 | 0.0735 | 67991 | 1137.7 |
| when_all waits _(N=2000)_ | 2000 | 0.0775 | 25822 | 1009.9 |

非严格 microbench（含 GC）。复现：`lua5.3 tools/bench_cont_fx.lua --json`。
