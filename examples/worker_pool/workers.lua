-- workers.lua — 「工人池」主模块：WorkerPool.run(opts) → result
-- 展示：有界 fx.chan 背压、map_parallel / lanes、supervise 脆弱工人、GameSim tick

local Cont = require("cont")
local Coro = require("coro")
local fx = require("fx")
local GameSim = require("game_sim")

local WorkerPool = {}

------------------------------------------------------------
-- 日志 / 世界
------------------------------------------------------------

local function make_world(sim, opts)
  local quiet = not not opts.quiet
  local log_lines = {}
  local function log(fmt, ...)
    local msg
    if select("#", ...) > 0 then
      msg = string.format(fmt, ...)
    else
      msg = tostring(fmt)
    end
    local line = string.format("[模拟 %.2fs] %s", sim:now(), msg)
    log_lines[#log_lines + 1] = line
    if not quiet then
      print(line)
    end
  end
  return {
    sim = sim,
    quiet = quiet,
    seed = opts.seed or 1,
    log = log,
    log_lines = log_lines,
    checks = {
      backpressure = false,
      flaky_failed = false,
      flaky_recovered = false,
      all_done = false,
      map_parallel = false,
      victory = false,
    },
    stats = {
      produced = 0,
      consumed = 0,
      results = 0,
      blocked_sends = 0,
      max_buf = 0,
    },
  }
end

local function register_kinds(sim)
  sim:register("anim", function(req, resume)
    local sec = req.seconds or 0.1
    sim.schedule(sec, function()
      resume({ ok = true, name = req.name or "anim" })
    end)
  end, { async = true })
end

local function anim(name, seconds)
  return Coro.yield({ kind = "anim", name = name, seconds = seconds or 0.1 })
end

------------------------------------------------------------
-- 生产者：往有界 job channel 塞任务（满则背压挂起）
------------------------------------------------------------

local function producer(world, job_ch, jobs)
  local function send_at(i)
    if i > #jobs then
      world.log("【生产者】全部投递完成 (%d 件)，关闭 job channel", #jobs)
      return fx.close(job_ch) >> function(_)
        return Cont.unit(#jobs)
      end
    end
    local job = jobs[i]
    -- 投递前观察缓冲：满则即将背压
    local buf_n = #job_ch.buf
    if buf_n > world.stats.max_buf then
      world.stats.max_buf = buf_n
    end
    if buf_n >= job_ch.capacity then
      world.stats.blocked_sends = world.stats.blocked_sends + 1
      world.checks.backpressure = true
      world.log("【生产者】背压：channel 已满 (buf=%d cap=%d)，send 将挂起 job#%d",
        buf_n, job_ch.capacity, job.id)
    end
    local t0 = world.sim:now()
    return fx.send(job_ch, job) >> function(_)
      local waited = world.sim:now() - t0
      world.stats.produced = world.stats.produced + 1
      if waited > 1e-9 then
        world.checks.backpressure = true
        world.log("【生产者】send job#%d 完成（曾挂起 %.2fs）", job.id, waited)
      else
        world.log("【生产者】send job#%d 立即入队", job.id)
      end
      return send_at(i + 1)
    end
  end
  return send_at(1)
end

------------------------------------------------------------
-- 工人：recv → 处理（wait/anim）→ send result；遇 chan_closed 退出
------------------------------------------------------------

local function process_job(world, worker_name, job)
  local work = job.work or 0.15
  world.log("【%s】开始处理 job#%d（work=%.2fs）", worker_name, job.id, work)
  return fx.wait(work * 0.5) >> function(_)
    return anim("work_" .. worker_name, work * 0.5) >> function(_)
      world.stats.consumed = world.stats.consumed + 1
      local result = {
        id = job.id,
        by = worker_name,
        payload = job.payload,
        t = world.sim:now(),
      }
      world.log("【%s】完成 job#%d", worker_name, job.id)
      return Cont.unit(result)
    end
  end
end

--- 普通工人循环
local function worker_loop(world, name, job_ch, result_ch)
  local function loop(_)
    return fx.recv(job_ch) >> function(job)
      return process_job(world, name, job) >> function(result)
        return fx.send(result_ch, result) >> function(_)
          world.stats.results = world.stats.results + 1
          return loop(nil)
        end
      end
    end
  end

  -- chan_closed 时 recv → Failed；用子 flow 隔离，主侧视为正常退出
  local body = loop(nil)
  local sub = world.sim:start_flow(nil, body)
  local function poll(_)
    if sub.done then
      local r = sub.result
      if r.ok then
        world.log("【%s】正常退出", name)
        return Cont.unit("ok")
      end
      local err = r.error
      local tag = type(err) == "table" and err.tag or err
      if tag == "chan_closed" or (type(err) == "table" and err.tag == "chan_closed") then
        world.log("【%s】job channel 关闭，退出", name)
        return Cont.unit("closed")
      end
      world.log("【%s】异常退出：%s", name, tostring(tag))
      return fx.fail(err)
    end
    return fx.wait(0.05) >> poll
  end
  return poll(nil)
end

--- 脆弱工人：首次处理故意 Failed，由 supervise 重启后恢复
local function flaky_worker(world, name, job_ch, result_ch)
  local attempts = { n = 0 }

  local function one_shot(_)
    attempts.n = attempts.n + 1
    if attempts.n == 1 then
      world.checks.flaky_failed = true
      world.log("【%s·supervise】首次启动抖动，Failed", name)
      return fx.fail({ tag = "worker_flaky", who = name })
    end
    world.checks.flaky_recovered = true
    world.log("【%s·supervise】恢复，进入正常循环", name)
    return worker_loop(world, name, job_ch, result_ch)
  end

  return fx.supervise(
    Cont.unit(true) >> one_shot,
    {
      max_restarts = 1,
      backoff = 0.05,
      on_fail = function(err)
        world.log("【%s·supervise】记录 Failed=%s",
          name, tostring(type(err) == "table" and err.tag or err))
        return true
      end,
    }
  )
end

------------------------------------------------------------
-- 结果收集器
------------------------------------------------------------

local function collector(world, result_ch, expect_n)
  local got = {}
  local function loop(_)
    if #got >= expect_n then
      world.log("【收集器】已收齐 %d 条结果，关闭 result channel", expect_n)
      return fx.close(result_ch) >> function(_)
        return Cont.unit(got)
      end
    end
    return fx.recv(result_ch) >> function(r)
      got[#got + 1] = r
      world.log("【收集器】recv 结果 #%d ← %s job#%d",
        #got, tostring(r.by), r.id)
      return loop(nil)
    end
  end
  return loop(nil)
end

------------------------------------------------------------
-- 主管道
------------------------------------------------------------

local function build_pool(world, opts)
  local n_workers = opts.n_workers or 3
  local n_jobs = opts.n_jobs or 8
  local job_cap = opts.job_cap or 2
  local result_cap = opts.result_cap or 4

  local jobs = {}
  for i = 1, n_jobs do
    jobs[i] = {
      id = i,
      payload = "任务-" .. i,
      work = 0.12 + (i % 3) * 0.03, -- 0.12 / 0.15 / 0.18
    }
  end

  local tostring = tostring
  return Cont.withEnv(function(_ENV)
    function init(_)
      world.log("【init】工人池启动 — workers=%d jobs=%d job_cap=%d",
        n_workers, n_jobs, job_cap)
      return Cont.unit(true)
    end

    function run_pool(_)
      local job_ch = fx.chan(job_cap)
      local result_ch = fx.chan(result_cap)
      world.log("【chan】job(cap=%d) / result(cap=%d)", job_cap, result_cap)

      -- 工人：用 map_parallel 有限并发拉起（含 1 个 flaky）
      local worker_specs = {}
      for i = 1, n_workers do
        worker_specs[i] = {
          name = (i == 1) and "脆弱工" or ("工人" .. i),
          flaky = (i == 1),
        }
      end

      local workers_ma = fx.map_parallel(worker_specs, function(spec, _idx)
        if spec.flaky then
          return flaky_worker(world, spec.name, job_ch, result_ch)
        end
        return worker_loop(world, spec.name, job_ch, result_ch)
      end, { concurrency = n_workers })

      world.checks.map_parallel = true

      -- 并行：生产者 + 工人池 + 收集器
      return fx.lanes({
        producer = producer(world, job_ch, jobs),
        workers = workers_ma,
        collector = collector(world, result_ch, n_jobs),
      }) >> function(vals)
        world.checks.all_done = true
        world.log("【汇合】producer/workers/collector 全部完成")
        return Cont.unit(vals)
      end
    end

    function summary(vals)
      local collected = vals and vals.collector or {}
      local ok = #collected >= (opts.n_jobs or 8)
        and world.checks.backpressure
        and world.checks.flaky_failed
        and world.checks.flaky_recovered
        and world.stats.produced >= (opts.n_jobs or 8)
      world.checks.victory = ok
      if ok then
        world.log("★★★ 胜利：%d 件任务处理完毕（背压=%s supervise=%s/%s）★★★",
          #collected,
          tostring(world.checks.backpressure),
          tostring(world.checks.flaky_failed),
          tostring(world.checks.flaky_recovered))
      else
        world.log("××× 失败：results=%d produced=%d backpressure=%s flaky=%s/%s ×××",
          #collected, world.stats.produced,
          tostring(world.checks.backpressure),
          tostring(world.checks.flaky_failed),
          tostring(world.checks.flaky_recovered))
      end
      return {
        victory = ok,
        results = #collected,
        produced = world.stats.produced,
        collected = collected,
      }
    end

    function finally(outcome)
      world.log("【finally】工人池结束 status=%s", tostring(outcome.status))
      return Cont.unit(true)
    end
  end)
end

------------------------------------------------------------
-- 驱动
------------------------------------------------------------

local function drive(world, flow, opts)
  local sim = world.sim
  local dt = opts.dt or 0.05
  local max_ticks = opts.max_ticks or 200000
  local n = 0
  while not flow.done do
    sim:tick(dt)
    n = n + 1
    if n > max_ticks then
      error(string.format(
        "WorkerPool: max_ticks=%d exceeded (t=%.3f)", max_ticks, sim:now()))
    end
  end
  return flow.result, n
end

local function run_asserts(world, flow_result, opts)
  local C = world.checks
  local function need(cond, msg)
    if not cond then
      error("WorkerPool assert failed: " .. msg)
    end
  end
  local n_jobs = opts.n_jobs or 8
  need(C.backpressure, "bounded chan should backpressure producer")
  need(C.flaky_failed and C.flaky_recovered, "flaky worker supervise recover")
  need(C.map_parallel, "map_parallel should launch workers")
  need(C.all_done, "lanes should join")
  need(C.victory, "pool victory")
  need(flow_result and flow_result.ok, "main flow Done ok")
  need(world.stats.produced >= n_jobs, "all jobs produced")
  need(world.stats.results >= n_jobs, "all results sent")
end

------------------------------------------------------------
-- API
------------------------------------------------------------

--- WorkerPool.run(opts?) → result
-- opts: quiet, assert, n_workers(3), n_jobs(8), job_cap(2), result_cap(4), dt, seed
function WorkerPool.run(opts)
  opts = opts or {}
  local quiet = opts.quiet
  if quiet == nil then
    quiet = opts.assert == true and opts.verbose ~= true
  end

  local sim = GameSim.new({ dt = opts.dt or 0.05 })
  local world = make_world(sim, {
    quiet = quiet,
    seed = opts.seed or 1,
  })
  register_kinds(sim)

  local pipe = build_pool(world, opts)
  local flow = sim:start_flow(nil, pipe(nil))
  local flow_result = select(1, drive(world, flow, opts))

  local summary = {
    ok = flow_result and flow_result.ok or false,
    victory = world.checks.victory,
    results = world.stats.results,
    produced = world.stats.produced,
    game_time = sim:now(),
    checks = world.checks,
    stats = world.stats,
    log_lines = world.log_lines,
    flow = flow_result,
  }

  if flow_result and flow_result.ok and type(flow_result.value) == "table" then
    summary.victory = flow_result.value.victory
    summary.results = flow_result.value.results or summary.results
    summary.produced = flow_result.value.produced or summary.produced
  end

  if opts.assert then
    run_asserts(world, flow_result, opts)
  end

  return summary
end

return WorkerPool
