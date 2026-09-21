-- combat.lua — 玩家战斗、宝箱并行、Boss 读条超时
-- 使用：anim kind、wait_event、when_all、fork/join、map_parallel、with_timeout

local Cont = require("cont")
local Coro = require("coro")
local fx = require("fx")
local World = require("world")

local Combat = {}

------------------------------------------------------------
-- 动画（自定义异步 kind，由 GameSim:register 兑现）
------------------------------------------------------------

function Combat.anim(name, seconds)
  return Coro.yield({ kind = "anim", name = name, seconds = seconds or 0.2 })
end

------------------------------------------------------------
-- 单怪对决：玩家挥砍 ↔ 接 mob_attack；击杀则 destroy → AI finally
------------------------------------------------------------

function Combat.fight_one(world, mob)
  local player = world.player
  local sim = world.sim

  local function round(_)
    if not World.alive(mob) then
      return Cont.unit("already_dead")
    end
    if not World.player_alive(world) then
      return fx.fail("player_dead")
    end

    -- 玩家挥砍（anim 占游戏时间）
    return Combat.anim("slash", 0.2) >> function(_)
      if not World.alive(mob) then
        return Cont.unit("killed_by_other")
      end
      mob.hp = mob.hp - player.atk
      -- 供萨满打断 / 刺客潜行窗口监听
      sim:emit("player_slash", { id = mob.id, target_id = mob.id, dmg = player.atk })
      world.log("【战斗】你对 %s 造成 %d 伤害（余 hp=%d）",
        mob.name, player.atk, math.max(mob.hp, 0))
      if mob.hp <= 0 then
        World.destroy_mob(world, mob, "player_kill")
        return Cont.unit("killed")
      end

      -- 并行：等该怪下一次攻击，或短暂窗口后继续挥砍
      return fx.when_any({
        fx.wait_event("mob_attack", function(p)
          return p and p.id == mob.id
        end) >> function(p)
          player.hp = player.hp - (p.dmg or 0)
          world.log("【战斗】你被 %s 击中 -%d（hp=%d）",
            mob.name, p.dmg or 0, player.hp)
          return Cont.unit("hit")
        end,
        fx.wait(0.25) >> function(_)
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

------------------------------------------------------------
-- 多怪：when_all 并行对决（房间 2）
------------------------------------------------------------

function Combat.fight_mobs_parallel(world, mobs)
  local tasks = {}
  for i = 1, #mobs do
    tasks[i] = Combat.fight_one(world, mobs[i])
  end
  world.log("【战斗】同时对阵 %d 只怪物（when_all）", #mobs)
  return fx.when_all(tasks) >> function(vals)
    world.log("【战斗】多怪战结束")
    return Cont.unit(vals)
  end
end

------------------------------------------------------------
-- 多怪备选：fork + join_handles（同语义展示）
------------------------------------------------------------

function Combat.fight_mobs_fork_join(world, mobs)
  world.log("【战斗】fork/join 对阵 %d 只", #mobs)
  local function fork_all(i, handles)
    if i > #mobs then
      return fx.join_handles(handles)
    end
    return fx.fork(Combat.fight_one(world, mobs[i])) >> function(h)
      handles[#handles + 1] = h
      return fork_all(i + 1, handles)
    end
  end
  return fork_all(1, {})
end

------------------------------------------------------------
-- 防御旁路：在主战斗之外监听任意 mob_attack（可选）
------------------------------------------------------------

function Combat.defend_poll(world, mobs, until_pred)
  local player = world.player
  local ids = {}
  for _, m in ipairs(mobs) do
    ids[m.id] = true
  end

  local function loop(_)
    if until_pred() then
      return Cont.unit("clear")
    end
    if not World.player_alive(world) then
      return fx.fail("player_dead")
    end
    return fx.when_any({
      fx.wait_event("mob_attack", function(p)
        return p and ids[p.id]
      end) >> function(p)
        player.hp = player.hp - (p.dmg or 0)
        world.log("【防御】额外承伤 %d → hp=%d", p.dmg or 0, player.hp)
        return Cont.unit(true)
      end,
      fx.wait(0.15) >> function(_)
        return Cont.unit("poll")
      end,
    }) >> function(_)
      return loop(nil)
    end
  end
  return loop(nil)
end

------------------------------------------------------------
-- 宝箱：map_parallel / when_all，游戏时间 ≈ max 而非求和
------------------------------------------------------------

function Combat.open_chests(world, chests)
  local sim = world.sim
  world.flags.chests_t0 = sim:now()
  world.log("【宝箱】并行开启 %d 个（map_parallel）", #chests)

  return fx.map_parallel(chests, function(chest, i)
    return fx.wait(chest.seconds) >> function(_)
      world.log("【宝箱】#%d「%s」打开 → +%s", i, chest.name, chest.loot)
      return Cont.unit({ name = chest.name, loot = chest.loot })
    end
  end, { concurrency = #chests }) >> function(loots)
    world.flags.chests_t1 = sim:now()
    local elapsed = world.flags.chests_t1 - world.flags.chests_t0
    local max_s = 0
    for _, c in ipairs(chests) do
      if c.seconds > max_s then
        max_s = c.seconds
      end
    end
    -- 并行：游戏时间应接近 max，而非 sum
    local ok = elapsed >= max_s - 1e-6 and elapsed < max_s + 0.35
    world.checks.chests_parallel = ok
    world.log("【宝箱】完成 elapsed=%.2f max=%.2f parallel=%s",
      elapsed, max_s, tostring(ok))
    return Cont.unit(loots)
  end
end

------------------------------------------------------------
-- Boss 读条：with_timeout 等打断事件；超时 → Failed 路径
-- 默认 run：调度提前 emit 打断 → 成功路径
-- opts.boss_mode = "timeout" 时不打断 → 处理 Failed
------------------------------------------------------------

function Combat.boss_channel_phase(world, boss, opts)
  opts = opts or {}
  local sim = world.sim
  local timeout = opts.channel_timeout or 1.6
  local interrupt_at = opts.interrupt_at -- nil → 走超时
  local mode = opts.boss_mode or "interrupt"

  world.log("【Boss】%s 开始读条（限时 %.2fs）", boss.name, timeout)

  -- 若打断模式：在游戏时间到达 interrupt_at 时 emit
  if mode == "interrupt" then
    local delay = interrupt_at or 0.7
    sim.schedule(delay, function()
      world.log("【Boss】你甩出打断技能！")
      sim:emit("boss_interrupt", { by = "player" })
    end)
  end

  -- with_timeout：限时内收到打断 → Done；否则 Failed("timeout")
  -- 由于 Failed 会中止整段 session，这里用子 flow 跑读条再解释结果
  return Combat._run_boss_subflow(world, boss, timeout, mode)
end

--- 子 flow：隔离 with_timeout 的 Failed，主流程可读 outcome
function Combat._run_boss_subflow(world, boss, timeout, mode)
  local sim = world.sim
  local Cont_unit = Cont.unit

  -- 把「启动子 flow + 等到 done」编成 Cont：用 wait 轮询（游戏时间）
  local channel_ma = fx.with_timeout(
    fx.wait_event("boss_interrupt") >> function(p)
      return Cont.unit({ path = "interrupt", payload = p })
    end,
    timeout,
    { on_timeout = "boss_cast_landed" }
  )

  local sub = sim:start_flow(nil, channel_ma)

  local function poll(_)
    if sub.done then
      local r = sub.result
      if r.ok then
        world.checks.boss_path = "interrupt"
        world.log("【Boss】读条被打断！path=interrupt")
        -- 打断成功：额外伤害
        boss.hp = boss.hp - 25
        world.log("【Boss】打断惩罚伤害 -25（余 hp=%d）", math.max(boss.hp, 0))
        return Cont_unit("interrupt")
      end
      -- Failed：超时读条命中
      world.checks.boss_path = "timeout"
      local dmg = boss.atk * 2
      world.player.hp = world.player.hp - dmg
      world.log("【Boss】读条完成命中！-%d（hp=%d）error=%s",
        dmg, world.player.hp, tostring(r.error))
      if not World.player_alive(world) then
        return fx.fail("player_dead")
      end
      return Cont_unit("timeout")
    end
    return fx.wait(0.05) >> function(_)
      return poll(nil)
    end
  end

  return poll(nil)
end

--- Boss 本体对决（读条后再打）
function Combat.fight_boss(world, boss, opts)
  return Combat.boss_channel_phase(world, boss, opts) >> function(path)
    world.log("【Boss】进入白刃战（读条结果=%s）", tostring(path))
    return Combat.fight_one(world, boss)
  end
end

return Combat
