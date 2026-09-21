-- fx_sched.lua — 并行 / nursery 调度器（时间轮）薄编排入口
--
-- 实现拆到：
--   fx_sched_util / fx_sched_chan / fx_sched_nursery /
--   fx_sched_supervise / fx_sched_drive / fx_sched_session
-- 共享袋 S 晚绑定，避免前向声明网；公共 API 与拆分前一致。
-- 详见 docs/核心整理说明.md

local M = {}
local S = {}

require("fx_sched_util").install(S, M)
require("fx_sched_chan").install(S)
require("fx_sched_nursery").install(S)
require("fx_sched_supervise").install(S)
require("fx_sched_drive").install(S)
require("fx_sched_session").install(S)
S.export_session(M)

return M
