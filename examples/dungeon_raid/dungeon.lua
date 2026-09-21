-- dungeon.lua — 「地牢突袭」主模块：DungeonRaid.run(opts) → result
-- 串联 Cont.withEnv + fx + GameSim，默认通关；opts.assert 做不变量自检。

local Cont = require("cont")
local fx = require("fx")
local GameSim = require("game_sim")
local World = require("world")
local AI = require("ai")
local Combat = require("combat")

local DungeonRaid = {}

------------------------------------------------------------
-- 注册自定义 kind
------------------------------------------------------------

local function register_kinds(sim, world)
  -- 攻击挥砍动画：异步，按游戏时间 schedule resume
  sim:register("anim", function(req, resume)
    local sec = req.seconds or 0.2
    if not world.quiet then
      -- 轻量：不每帧刷屏，仅 debug 时可开
    end
    sim.schedule(sec, function()
      resume({ ok = true, name = req.name or "anim" })
    end)
  end, { async = true })
end

------------------------------------------------------------
-- 房间脚本
------------------------------------------------------------

local function room1_corridor(world)
  local mob = World.spawn_mob(world, {
    name = "地精斥候",
    hp = 30,
    atk = 6,
    windup = 0.4,
    cooldown = 0.6,
  })
  AI.start(world, mob)
  world.log("==== 房间 1：阴湿走廊 ====")
  return Combat.fight_one(world, mob) >> function(_)
    world.rooms_cleared = world.rooms_cleared + 1
    world.log("走廊肃清。hp=%d", world.player.hp)
    return Cont.unit(true)
  end
end

local function travel_and_pause_flag(world)
  -- 通知外层 tick 循环：下一拍做 pause 校验
  world.flags.ready_for_pause = true
  world.log("==== 前往下一房间（旅途中将演示 pause）====")
  return fx.wait(0.8) >> function(_)
    world.log("旅途结束 @%.2f", world.sim:now())
    return Cont.unit(true)
  end
end

local function room2_undead(world)
  world.log("==== 房间 2：骸骨密室 ====")
  local a = World.spawn_mob(world, {
    name = "骷髅剑士",
    hp = 35,
    atk = 8,
    windup = 0.35,
    cooldown = 0.5,
  })
  local b = World.spawn_mob(world, {
    name = "骷髅弓手",
    hp = 28,
    atk = 7,
    windup = 0.45,
    cooldown = 0.55,
  })
  AI.start(world, a)
  AI.start(world, b)
  -- 多怪并行：when_all
  return Combat.fight_mobs_parallel(world, { a, b }) >> function(_)
    world.rooms_cleared = world.rooms_cleared + 1
    world.log("密室肃清。hp=%d", world.player.hp)
    return Cont.unit(true)
  end
end

local function loot_chests(world)
  world.log("==== 战利品：双宝箱 ====")
  return Combat.open_chests(world, {
    { name = "木箱", seconds = 0.40, loot = "小药水" },
    { name = "铁箱", seconds = 0.65, loot = "锋利短剑(+0 atk 剧情)" },
  }) >> function(loots)
    -- 喝药回一点血（叙事）
    world.player.hp = math.min(world.player.max_hp, world.player.hp + 15)
    world.log("使用小药水，hp=%d", world.player.hp)
    return Cont.unit(loots)
  end
end

local function room3_boss(world, opts)
  world.log("==== 房间 3：Boss 厅 ====")
  local boss = World.spawn_mob(world, {
    name = "地牢领主",
    hp = 70,
    atk = 12,
    windup = 0.5,
    cooldown = 0.7,
    kind = "boss",
  })
  AI.start(world, boss)
  return Combat.fight_boss(world, boss, {
    boss_mode = opts.boss_mode or "interrupt",
    channel_timeout = opts.channel_timeout or 1.6,
    interrupt_at = opts.interrupt_at or 0.6,
  }) >> function(_)
    world.rooms_cleared = world.rooms_cleared + 1
    world.log("领主倒下！hp=%d", world.player.hp)
    return Cont.unit(true)
  end
end

------------------------------------------------------------
-- 主管道 withEnv
------------------------------------------------------------

local function build_dungeon(world, opts)
  local tostring = tostring
  return Cont.withEnv(function(_ENV)
    function init(_)
      world.log("【init】地牢突袭开始 — 种子=%s", tostring(world.seed))
      world.log("玩家 %s hp=%d atk=%d", world.player.name, world.player.hp, world.player.atk)
      return Cont.unit(true)
    end

    function enter_corridor(_)
      return room1_corridor(world)
    end

    function travel(_)
      return travel_and_pause_flag(world)
    end

    function enter_crypt(_)
      return room2_undead(world)
    end

    function open_loot(_)
      return loot_chests(world)
    end

    function enter_boss(_)
      return room3_boss(world, opts)
    end

    -- 普通步骤：结算
    function summary(_)
      local ok = World.player_alive(world) and world.rooms_cleared >= 3
      world.checks.victory = ok
      if ok then
        world.log("★★★ 胜利：地牢已清空，剩余 hp=%d ★★★", world.player.hp)
      else
        world.log("××× 失败：hp=%d rooms=%d ×××", world.player.hp, world.rooms_cleared)
      end
      return {
        victory = ok,
        hp = world.player.hp,
        rooms = world.rooms_cleared,
      }
    end

    function finally(outcome)
      world.log("【finally】地牢流程结束 status=%s", tostring(outcome.status))
      return Cont.unit(true)
    end
  end)
end

------------------------------------------------------------
-- 驱动：手动 tick，以便中途 pause
------------------------------------------------------------

local function drive_with_pause(world, flow, opts)
  local sim = world.sim
  local dt = opts.dt or 0.05
  local max_ticks = opts.max_ticks or 200000
  local n = 0
  local did_pause = false

  while not flow.done do
    if (not did_pause) and world.flags.ready_for_pause then
      world.flags.ready_for_pause = false
      did_pause = true
      local t_freeze = sim:now()
      world.log("【pause】暂停游戏 @%.2f（验证 wait 不推进）", t_freeze)
      sim:set_paused(true)
      for _ = 1, 8 do
        sim:tick(dt)
      end
      local still = sim:now()
      world.checks.pause_deferred = (math.abs(still - t_freeze) < 1e-9) and (not flow.done)
      world.log("【pause】暂停期间 now=%.2f deferred=%s",
        still, tostring(world.checks.pause_deferred))
      sim:set_paused(false)
      world.log("【pause】恢复")
    end

    sim:tick(dt)
    n = n + 1
    if n > max_ticks then
      error(string.format(
        "DungeonRaid: max_ticks=%d exceeded (t=%.3f)", max_ticks, sim:now()))
    end
  end
  return flow.result, n
end

------------------------------------------------------------
-- 自检
------------------------------------------------------------

local function run_asserts(world, flow_result, opts)
  local C = world.checks
  local function need(cond, msg)
    if not cond then
      error("DungeonRaid assert failed: " .. msg)
    end
  end

  need(C.pause_deferred, "pause should defer wait")
  need(C.mob_finally, "mob destroy should run finally")
  need(C.chests_parallel, "chests wall game-time should ≈ max")
  need(C.boss_path == "interrupt" or C.boss_path == "timeout",
    "boss path must be interrupt or timeout")
  if (opts.boss_mode or "interrupt") == "interrupt" then
    need(C.boss_path == "interrupt", "default boss path is interrupt")
  end
  if (opts.boss_mode or "interrupt") == "timeout" then
    need(C.boss_path == "timeout", "timeout mode boss path")
  end
  need(C.victory, "player should clear dungeon with hp>0")
  need(flow_result and flow_result.ok, "main flow should Done ok")
  need(World.player_alive(world), "player alive")
  need(world.rooms_cleared >= 3, "three rooms cleared")

  -- 至少一只怪 finally_ran
  local any_fin = false
  for _, m in pairs(world.mob_meta) do
    if m.finally_ran then
      any_fin = true
      break
    end
  end
  need(any_fin, "at least one mob finally_ran")
end

------------------------------------------------------------
-- 公开 API
------------------------------------------------------------

--- DungeonRaid.run(opts?) → result
-- opts:
--   quiet / verbose：日志
--   assert=true：跑完后断言不变量
--   boss_mode="interrupt"|"timeout"
--   dt, max_ticks, seed, channel_timeout, interrupt_at
-- result:
--   ok, victory, hp, rooms, game_time, checks, log_lines, flow
function DungeonRaid.run(opts)
  opts = opts or {}
  local quiet = opts.quiet
  if quiet == nil then
    quiet = opts.assert == true and opts.verbose ~= true
  end

  local sim = GameSim.new({ dt = opts.dt or 0.05 })
  local world = World.create(sim, {
    quiet = quiet,
    seed = opts.seed or 1,
  })
  register_kinds(sim, world)

  local pipe = build_dungeon(world, opts)
  local flow = sim:start_flow(nil, pipe(nil))
  local flow_result = select(1, drive_with_pause(world, flow, opts))

  local summary = {
    ok = flow_result and flow_result.ok or false,
    victory = world.checks.victory,
    hp = world.player.hp,
    rooms = world.rooms_cleared,
    game_time = sim:now(),
    checks = world.checks,
    log_lines = world.log_lines,
    flow = flow_result,
    boss_path = world.checks.boss_path,
  }

  if flow_result and flow_result.ok and type(flow_result.value) == "table" then
    summary.victory = flow_result.value.victory
    summary.hp = flow_result.value.hp or summary.hp
    summary.rooms = flow_result.value.rooms or summary.rooms
  end

  if opts.assert then
    run_asserts(world, flow_result, opts)
  end

  return summary
end

--- 缩短场景：只测 pause / finally / chests / boss 之一（供测试）
function DungeonRaid.run_focus(focus, opts)
  opts = opts or {}
  opts.quiet = opts.quiet ~= false
  if focus == "full" then
    opts.assert = true
    return DungeonRaid.run(opts)
  end

  local sim = GameSim.new({ dt = opts.dt or 0.05 })
  local world = World.create(sim, { quiet = true, seed = 1 })
  register_kinds(sim, world)

  if focus == "pause" then
    local flow = sim:start_flow(nil, fx.wait(0.5) >> function(_)
      return Cont.unit(true)
    end)
    sim:tick(0.1)
    sim:set_paused(true)
    local t = sim:now()
    for _ = 1, 10 do sim:tick(0.1) end
    assert(sim:now() == t and not flow.done)
    sim:set_paused(false)
    while not flow.done do sim:tick(0.05) end
    return { ok = true, focus = "pause" }
  end

  if focus == "finally" then
    local mob = World.spawn_mob(world, { name = "测试史莱姆", hp = 10, atk = 1 })
    AI.start(world, mob)
    sim:tick(0.05)
    World.destroy_mob(world, mob, "test")
    assert(world.mob_meta[mob.id].finally_ran, "finally")
    return { ok = true, focus = "finally" }
  end

  if focus == "chests" then
    local ma = Combat.open_chests(world, {
      { name = "A", seconds = 0.3, loot = "x" },
      { name = "B", seconds = 0.5, loot = "y" },
    })
    local r = sim:run(ma)
    assert(r.ok and world.checks.chests_parallel)
    return { ok = true, focus = "chests", game_time = sim:now() }
  end

  if focus == "boss_timeout" then
    opts.boss_mode = "timeout"
    opts.assert = false
    -- 迷你：只跑 boss 读条
    local boss = World.spawn_mob(world, { name = "木桩领主", hp = 50, atk = 5 })
    local ma = Combat.boss_channel_phase(world, boss, {
      boss_mode = "timeout",
      channel_timeout = 0.4,
    })
    local r = sim:run(ma)
    assert(r.ok and world.checks.boss_path == "timeout")
    return { ok = true, focus = "boss_timeout" }
  end

  if focus == "boss_interrupt" then
    local boss = World.spawn_mob(world, { name = "木桩领主", hp = 50, atk = 5 })
    local ma = Combat.boss_channel_phase(world, boss, {
      boss_mode = "interrupt",
      channel_timeout = 1.0,
      interrupt_at = 0.3,
    })
    local r = sim:run(ma)
    assert(r.ok and world.checks.boss_path == "interrupt")
    return { ok = true, focus = "boss_interrupt" }
  end

  error("unknown focus: " .. tostring(focus))
end

return DungeonRaid
