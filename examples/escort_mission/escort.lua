-- escort.lua — 「护卫任务」主模块：EscortMission.run(opts) → result
-- 展示：fx.lanes / fx.proxy / fx.chan / fx.supervise / with_timeout / GameSim pause·destroy·finally

local Cont = require("cont")
local Coro = require("coro")
local fx = require("fx")
local GameSim = require("game_sim")
local World = require("escort_world")

local EscortMission = {}

------------------------------------------------------------
-- 自定义异步 kind
------------------------------------------------------------

local function register_kinds(sim, _world)
  sim:register("anim", function(req, resume)
    local sec = req.seconds or 0.15
    sim.schedule(sec, function()
      resume({ ok = true, name = req.name or "anim" })
    end)
  end, { async = true })
end

local function anim(name, seconds)
  return Coro.yield({ kind = "anim", name = name, seconds = seconds or 0.15 })
end

------------------------------------------------------------
-- 伏击 AI：首次 Failed → supervise 重启一次；destroy → finally
------------------------------------------------------------

local function make_ambush_ai(world, enemy)
  local meta = world.enemy_meta[enemy.id]
  local attempts = { n = 0 }
  local tostring = tostring

  local function hunt_once(_)
    attempts.n = attempts.n + 1
    -- 第一次故意失败，展示 supervise 唯一一次重启
    if attempts.n == 1 then
      world.checks.ambush_supervise_failed = true
      world.log("【伏击·supervise】%s 首次突袭失手（Failed）", enemy.name)
      return fx.fail({ tag = "ambush_misfire", who = enemy.name })
    end
    world.checks.ambush_supervised = true
    world.log("【伏击·supervise】%s 重整阵型，开始循环进攻", enemy.name)

    local function loop(_)
      if not World.alive(enemy) then
        return Cont.unit("dead")
      end
      return fx.wait(enemy.windup) >> function(_)
        if not World.alive(enemy) then
          return Cont.unit("dead")
        end
        world.sim:emit("enemy_attack", {
          id = enemy.id,
          name = enemy.name,
          dmg = enemy.atk,
        })
        world.log("【伏击】%s 发动攻击 dmg=%d", enemy.name, enemy.atk)
        return fx.wait(enemy.cooldown) >> function(_)
          return loop(nil)
        end
      end
    end
    return loop(nil)
  end

  return Cont.withEnv(function(_ENV)
    function init(_)
      world.log("【伏击·init】%s 进入战场", enemy.name)
      return true
    end

    function hunt(_)
      return fx.supervise(
        Cont.unit(true) >> hunt_once,
        {
          max_restarts = 1,
          backoff = 0.05,
          on_fail = function(err)
            world.log("【伏击·supervise】记录 Failed=%s，准备唯一一次重启",
              tostring(type(err) == "table" and err.tag or err))
            return true
          end,
        }
      )
    end

    function finally(outcome)
      meta.finally_ran = true
      meta.outcome = outcome.status
      world.checks.enemy_finally = true
      world.log("【伏击·finally】%s status=%s → 清理伏击标记",
        enemy.name, tostring(outcome.status))
      return Cont.unit(true)
    end
  end)
end

local function start_ambush(world, enemy)
  local pipe = make_ambush_ai(world, enemy)
  local flow = world.sim:start_flow(enemy.entity, pipe(nil))
  enemy.ai_flow = flow
  return flow
end

------------------------------------------------------------
-- 车道：护卫移动（escort）
------------------------------------------------------------

local function escort_lane(world, checkpoint_ch, alert_ch)
  local cps = world.checkpoints
  local escort = world.escort

  local function go_to(i)
    if i > #cps then
      world.flags.escort_arrived = true
      world.log("【护卫车道】商队抵达终点")
      return Cont.unit({ arrived = #cps })
    end
    local cp = cps[i]
    world.log("【护卫车道】前往检查点「%s」（行程 %.2fs）", cp.name, cp.travel)

    -- 中段（河湾）触发 pause 演示
    if i == 2 then
      world.flags.ready_for_pause = true
    end

    return fx.wait(cp.travel) >> function(_)
      if not World.escort_alive(world) then
        return fx.fail("escort_dead")
      end
      escort.pos = i
      world.arrived_count = world.arrived_count + 1
      world.log("【护卫车道】抵达「%s」（累计 %d/%d）",
        cp.name, world.arrived_count, #cps)

      -- 通知 channel：检查点到达
      return fx.send(checkpoint_ch, {
        index = i,
        name = cp.name,
        t = world.sim:now(),
      }) >> function(_)
        world.checks.checkpoint_chan = true

        -- 河湾：进入救援窗（with_timeout）；需等玩家清掉伏击
        if i == 2 then
          world.log("【护卫车道】河湾遇袭！开启救援窗口")
          local rescue_ma = fx.with_timeout(
            fx.wait_until(function()
              return world.flags.ambush_cleared and "rescued"
            end),
            2.0,
            { on_timeout = "rescue_timeout" }
          )
          -- 子 flow 隔离 Failed
          local sub = world.sim:start_flow(nil, rescue_ma)
          local function poll(_)
            if sub.done then
              local r = sub.result
              if r.ok then
                world.checks.rescue_ok = true
                world.log("【护卫车道】救援成功 path=rescued")
                return Cont.unit("rescued")
              end
              world.log("【护卫车道】救援超时！error=%s", tostring(r.error))
              return fx.fail("rescue_timeout")
            end
            return fx.wait(0.05) >> poll
          end
          return poll(nil) >> function(_)
            return go_to(i + 1)
          end
        end

        return go_to(i + 1)
      end
    end
  end

  -- 旁听伤害警报（不阻塞主行程：fork 收一条即可）
  local listen_alert = fx.fork(
    fx.recv(alert_ch) >> function(msg)
      world.checks.alert_chan = true
      world.log("【护卫车道·alert】收到伤害警报：%s -%d",
        tostring(msg.from), msg.dmg or 0)
      return Cont.unit(msg)
    end
  )

  return listen_alert >> function(alert_h)
    return go_to(1) >> function(arrived)
      -- 确保威胁/伤害警报已被旁路消费
      return fx.join(alert_h) >> function(_)
        return Cont.unit(arrived)
      end
    end
  end
end

------------------------------------------------------------
-- 车道：玩家战斗（combat）
------------------------------------------------------------

local function combat_lane(world, alert_ch)
  world.log("【战斗车道】警戒中，等待河湾伏击……")
  -- 等到护卫接近河湾（pos>=1 即西门已过，或直接等短暂延时后刷怪）
  return fx.wait(0.50) >> function(_)
    local enemy = World.spawn_enemy(world, {
      name = "山贼斥候",
      hp = 45,
      atk = 9,
      windup = 0.20,
      cooldown = 0.35,
    })
    start_ambush(world, enemy)
    world.log("【战斗车道】遭遇 %s！", enemy.name)

    -- 先发威胁警报，保证 alert channel 必达（不依赖是否挨打）
    return fx.send(alert_ch, {
      from = enemy.name,
      dmg = 0,
      kind = "threat",
      t = world.sim:now(),
    }) >> function(_)
      world.log("【战斗车道】已发送威胁警报")

      local function round(_)
        if not World.alive(enemy) then
          world.flags.ambush_cleared = true
          world.log("【战斗车道】伏击已清除")
          return Cont.unit("cleared")
        end
        if not World.player_alive(world) then
          return fx.fail("player_dead")
        end

        return anim("slash", 0.18) >> function(_)
          if not World.alive(enemy) then
            world.flags.ambush_cleared = true
            return Cont.unit("cleared")
          end
          enemy.hp = enemy.hp - world.player.atk
          world.log("【战斗】你对 %s 造成 %d 伤害（余 hp=%d）",
            enemy.name, world.player.atk, math.max(enemy.hp, 0))
          if enemy.hp <= 0 then
            World.destroy_enemy(world, enemy, "player_kill")
            world.flags.ambush_cleared = true
            return Cont.unit("killed")
          end

          return fx.when_any({
            fx.wait_event("enemy_attack", function(p)
              return p and p.id == enemy.id
            end) >> function(p)
              world.player.hp = world.player.hp - (p.dmg or 0)
              world.escort.hp = world.escort.hp - math.floor((p.dmg or 0) * 0.5)
              world.log("【战斗】你被击中 -%d（hp=%d）；商队余 hp=%d",
                p.dmg or 0, world.player.hp, world.escort.hp)
              return Cont.unit("hit")
            end,
            fx.wait(0.22) >> function(_)
              return Cont.unit("riposte")
            end,
          }) >> function(_)
            if not World.player_alive(world) then
              return fx.fail("player_dead")
            end
            return round(nil)
          end
        end
      end

      return round(nil)
    end
  end
end

------------------------------------------------------------
-- HUD：proxy 加入 escort 车道（不拥有 Cont）
------------------------------------------------------------

local function hud_proxy_waiter(world)
  world.log("【HUD·proxy】挂接护卫车道（proxy_join escort）")
  return fx.proxy_join(fx.proxy("escort")) >> function(v)
    world.checks.hud_proxy = true
    world.log("【HUD·proxy】护卫车道完成，同步结算 value.arrived=%s",
      tostring(type(v) == "table" and v.arrived or v))
    return Cont.unit(v)
  end
end

------------------------------------------------------------
-- 主管道
------------------------------------------------------------

local function build_mission(world, _opts)
  local tostring = tostring
  return Cont.withEnv(function(_ENV)
    function init(_)
      world.log("【init】护卫任务开始 — 种子=%s", tostring(world.seed))
      world.log("玩家 %s hp=%d；护送 %s hp=%d；检查点 %d 个",
        world.player.name, world.player.hp,
        world.escort.name, world.escort.hp,
        #world.checkpoints)
      return Cont.unit(true)
    end

    function run_lanes(_)
      local checkpoint_ch = fx.chan(3)
      local alert_ch = fx.chan(1)
      world.log("【chan】建立 checkpoint(cap=3) / alert(cap=1)")

      -- 显式 lane + proxy，而非一次性 lanes 汇合：HUD 可在车道存活期挂接
      return fx.lane("escort", escort_lane(world, checkpoint_ch, alert_ch)) >> function(escort_h)
        return fx.lane("combat", combat_lane(world, alert_ch)) >> function(combat_h)
          world.checks.lanes_used = true
          world.log("【lanes】已启动 escort + combat")
          return fx.fork(hud_proxy_waiter(world)) >> function(hud_h)
            return fx.join_handles({ escort_h, combat_h, hud_h }) >> function(vals)
              world.log("【lanes】全部汇合")
              return fx.close(checkpoint_ch) >> function(_)
                return fx.close(alert_ch) >> function(_)
                  return Cont.unit({
                    escort = vals[1],
                    combat = vals[2],
                    hud = vals[3],
                  })
                end
              end
            end
          end
        end
      end
    end

    function summary(_)
      local ok = World.player_alive(world)
        and World.escort_alive(world)
        and world.arrived_count >= #world.checkpoints
        and world.flags.ambush_cleared
        and world.checks.rescue_ok
      world.checks.victory = ok
      if ok then
        world.log("★★★ 胜利：商队安全抵达，剩余玩家 hp=%d 商队 hp=%d ★★★",
          world.player.hp, world.escort.hp)
      else
        world.log("××× 失败：player_hp=%d escort_hp=%d arrived=%d ambush=%s rescue=%s ×××",
          world.player.hp, world.escort.hp, world.arrived_count,
          tostring(world.flags.ambush_cleared), tostring(world.checks.rescue_ok))
      end
      return {
        victory = ok,
        hp = world.player.hp,
        escort_hp = world.escort.hp,
        arrived = world.arrived_count,
      }
    end

    function finally(outcome)
      world.log("【finally】护卫任务结束 status=%s", tostring(outcome.status))
      return Cont.unit(true)
    end
  end)
end

------------------------------------------------------------
-- 驱动：中途 pause
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
      world.log("【pause】暂停游戏 @%.2f", t_freeze)
      sim:set_paused(true)
      local pause_ticks = 6
      for _ = 1, pause_ticks do
        sim:tick(dt)
      end
      local still = sim:now()
      world.checks.pause_deferred = (math.abs(still - t_freeze) < 1e-9) and (not flow.done)
      world.log("【pause】期间 tick %d 次，游戏时间仍为 %.2f；流程挂起=%s",
        pause_ticks, still, tostring(not flow.done))
      sim:set_paused(false)
      world.log("【pause】恢复 @%.2f", still)
    end

    sim:tick(dt)
    n = n + 1
    if n > max_ticks then
      error(string.format(
        "EscortMission: max_ticks=%d exceeded (t=%.3f)", max_ticks, sim:now()))
    end
  end
  return flow.result, n
end

------------------------------------------------------------
-- 自检
------------------------------------------------------------

local function run_asserts(world, flow_result, _opts)
  local C = world.checks
  local function need(cond, msg)
    if not cond then
      error("EscortMission assert failed: " .. msg)
    end
  end

  need(C.pause_deferred, "pause should defer wait")
  need(C.enemy_finally, "enemy destroy should run finally")
  need(C.lanes_used, "lanes should be started")
  need(C.hud_proxy, "HUD proxy_join escort should succeed")
  need(C.checkpoint_chan, "checkpoint channel send should happen")
  need(C.alert_chan, "damage alert channel should be received")
  need(C.ambush_supervise_failed and C.ambush_supervised,
    "ambush supervise should fail once then recover")
  need(C.rescue_ok, "rescue with_timeout window should succeed")
  need(C.victory, "mission victory")
  need(flow_result and flow_result.ok, "main flow Done ok")
  need(World.player_alive(world), "player alive")
  need(World.escort_alive(world), "escort alive")
  need(world.arrived_count >= #world.checkpoints, "all checkpoints")
end

------------------------------------------------------------
-- 公开 API
------------------------------------------------------------

--- EscortMission.run(opts?) → result
function EscortMission.run(opts)
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

  local pipe = build_mission(world, opts)
  local flow = sim:start_flow(nil, pipe(nil))
  local flow_result = select(1, drive_with_pause(world, flow, opts))

  local summary = {
    ok = flow_result and flow_result.ok or false,
    victory = world.checks.victory,
    hp = world.player.hp,
    escort_hp = world.escort.hp,
    arrived = world.arrived_count,
    game_time = sim:now(),
    checks = world.checks,
    log_lines = world.log_lines,
    flow = flow_result,
  }

  if flow_result and flow_result.ok and type(flow_result.value) == "table" then
    summary.victory = flow_result.value.victory
    summary.hp = flow_result.value.hp or summary.hp
    summary.escort_hp = flow_result.value.escort_hp or summary.escort_hp
    summary.arrived = flow_result.value.arrived or summary.arrived
  end

  if opts.assert then
    run_asserts(world, flow_result, opts)
  end

  return summary
end

return EscortMission
