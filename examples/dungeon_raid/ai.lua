-- ai.lua — 怪物 AI：Cont.withEnv + init/finally + wait/emit 循环
-- 基础 AI + 狂战士 / 萨满 / 刺客（展示 Cont/fx/GameSim：相位、可打断读条、召唤、when_any、wait_event、finally）
-- destroy_entity 取消绑定 flow 时 finally 必跑（校验 cleanup / 掉落标志）

local Cont = require("cont")
local fx = require("fx")
local World = require("world")

local AI = {}

------------------------------------------------------------
-- 公共：withEnv 外壳（init / hunt / finally）
------------------------------------------------------------

local function wrap_ai(world, mob, hunt_fn, finally_extra)
  local meta = world.mob_meta[mob.id]
  local tostring = tostring

  return Cont.withEnv(function(_ENV)
    function init(_)
      world.log("【AI·init】%s 进入仇恨（ai=%s）", mob.name, tostring(mob.ai or mob.kind or "basic"))
      return true
    end

    function hunt(_)
      return hunt_fn(world, mob)
    end

    function finally(outcome)
      meta.finally_ran = true
      meta.dropped = true
      meta.outcome = outcome.status
      meta.reason = outcome.reason or outcome.error
      world.checks.mob_finally = true
      if finally_extra then
        finally_extra(world, mob, outcome)
      end
      world.log("【AI·finally】%s status=%s reason=%s → 掉落标记",
        mob.name, tostring(outcome.status), tostring(meta.reason))
      return Cont.unit(true)
    end
  end)
end

------------------------------------------------------------
-- 基础攻击循环（kind=normal / basic / boss / 默认）
------------------------------------------------------------

function AI._attack_loop(world, mob)
  local sim = world.sim
  return fx.wait(mob.windup) >> function(_)
    if not World.alive(mob) then
      return Cont.unit("dead")
    end
    world.log("【AI】%s 发动攻击 dmg=%d", mob.name, mob.atk)
    sim:emit("mob_attack", { id = mob.id, name = mob.name, dmg = mob.atk })
    return fx.wait(mob.cooldown) >> function(_)
      if not World.alive(mob) then
        return Cont.unit("dead")
      end
      return AI._attack_loop(world, mob)
    end
  end
end

function AI.make_mob_ai(world, mob)
  return wrap_ai(world, mob, AI._attack_loop)
end

------------------------------------------------------------
-- 狂战士：hp≤50% 进入狂暴（更短风摇、更高 atk）
------------------------------------------------------------

local function berserker_try_enrage(world, mob)
  local meta = world.mob_meta[mob.id]
  if meta.enraged then
    return
  end
  if mob.hp > 0 and mob.hp <= (mob.max_hp * 0.5) then
    meta.enraged = true
    world.checks.berserker_enraged = true
    mob.atk = math.floor(mob.atk * 1.6 + 0.5)
    mob.windup = math.max(0.12, (mob.windup or 0.35) * 0.45)
    mob.cooldown = math.max(0.18, (mob.cooldown or 0.55) * 0.55)
    world.log("【AI·狂战士】%s 暴怒！atk→%d windup→%.2f", mob.name, mob.atk, mob.windup)
  end
end

function AI._berserker_loop(world, mob)
  local sim = world.sim
  local meta = world.mob_meta[mob.id]

  berserker_try_enrage(world, mob)

  return fx.wait(mob.windup) >> function(_)
    if not World.alive(mob) then
      return Cont.unit("dead")
    end
    -- 风摇期间可能被打到半血以下 → 出招前再检一次
    berserker_try_enrage(world, mob)
    world.log("【AI·狂战士】%s 发动攻击 dmg=%d%s",
      mob.name, mob.atk, meta.enraged and "（狂暴）" or "")
    sim:emit("mob_attack", { id = mob.id, name = mob.name, dmg = mob.atk })
    return fx.wait(mob.cooldown) >> function(_)
      if not World.alive(mob) then
        return Cont.unit("dead")
      end
      return AI._berserker_loop(world, mob)
    end
  end
end

function AI.make_berserker_ai(world, mob)
  return wrap_ai(world, mob, AI._berserker_loop)
end

------------------------------------------------------------
-- 萨满：可打断读条治疗 + 偶尔召唤弱小 add；finally 清理召唤物
------------------------------------------------------------

function AI._shaman_summon(world, mob)
  local meta = world.mob_meta[mob.id]
  meta.adds = meta.adds or {}
  local add = World.spawn_mob(world, {
    name = mob.name .. "·图腾灵",
    hp = 12,
    atk = 3,
    windup = 0.5,
    cooldown = 0.7,
    ai = "basic",
    kind = "normal",
  })
  meta.adds[#meta.adds + 1] = add
  world.checks.shaman_summoned = true
  world.log("【AI·萨满】%s 召唤 %s", mob.name, add.name)
  AI.start(world, add)
  return Cont.unit(add)
end

function AI._shaman_cast(world, mob)
  local sim = world.sim
  local cast_time = mob.cast_time or 0.65
  world.log("【AI·萨满】%s 开始引导治疗（%.2fs，可被挥砍打断）", mob.name, cast_time)
  sim:emit("mob_cast_start", { id = mob.id, name = mob.name, skill = "heal" })

  return fx.when_any({
    fx.wait(cast_time) >> function(_)
      return Cont.unit("cast_ok")
    end,
    fx.wait_event("player_slash", function(p)
      return p and (p.id == mob.id or p.target_id == mob.id)
    end) >> function(_)
      return Cont.unit("interrupted")
    end,
  }) >> function(winner)
    -- 先根据胜者记账（击杀挥砍会先扣 hp 再 emit，不能因已死丢标志）
    local v = winner and winner.value
    if v == "interrupted" then
      world.checks.shaman_interrupted = true
      world.log("【AI·萨满】%s 引导被打断！", mob.name)
      return Cont.unit("interrupted")
    end
    if not World.alive(mob) then
      return Cont.unit("dead")
    end
    if v == "cast_ok" then
      local heal = mob.heal_amount or 10
      mob.hp = math.min(mob.max_hp, mob.hp + heal)
      world.log("【AI·萨满】%s 治疗成功 +%d（hp=%d）", mob.name, heal, mob.hp)
      return Cont.unit("healed")
    end
    return Cont.unit(v or "cast_end")
  end
end

function AI._shaman_loop(world, mob)
  local meta = world.mob_meta[mob.id]
  meta.cycle = (meta.cycle or 0) + 1

  return fx.wait(mob.windup or 0.28) >> function(_)
    if not World.alive(mob) then
      return Cont.unit("dead")
    end

    -- 首周期召唤，保证完整通关能看到召唤 + finally cleanup
    local after_summon = Cont.unit(true)
    if meta.cycle == 1 or (meta.cycle > 1 and meta.cycle % 4 == 0) then
      after_summon = AI._shaman_summon(world, mob)
    end

    return after_summon >> function(_)
      if not World.alive(mob) then
        return Cont.unit("dead")
      end
      return AI._shaman_cast(world, mob) >> function(_)
        if not World.alive(mob) then
          return Cont.unit("dead")
        end
        world.log("【AI·萨满】%s 甩出法术飞弹 dmg=%d", mob.name, mob.atk)
        world.sim:emit("mob_attack", { id = mob.id, name = mob.name, dmg = mob.atk })
        return fx.wait(mob.cooldown or 0.4) >> function(_)
          if not World.alive(mob) then
            return Cont.unit("dead")
          end
          return AI._shaman_loop(world, mob)
        end
      end
    end
  end
end

local function shaman_finally_cleanup(world, mob, _)
  local meta = world.mob_meta[mob.id]
  local adds = meta and meta.adds
  if not adds then
    return
  end
  for _, add in ipairs(adds) do
    if World.alive(add) then
      world.log("【AI·萨满·cleanup】清除残留召唤物 %s", add.name)
      World.destroy_mob(world, add, "summoner_dead")
    end
  end
end

function AI.make_shaman_ai(world, mob)
  world.mob_meta[mob.id].adds = {}
  return wrap_ai(world, mob, AI._shaman_loop, shaman_finally_cleanup)
end

------------------------------------------------------------
-- 刺客：潜行 → when_any(被砍打断 / 延时伏击大伤害) → 再转入普攻
------------------------------------------------------------

function AI._assassin_basic_after(world, mob)
  return AI._attack_loop(world, mob)
end

function AI._assassin_loop(world, mob)
  local sim = world.sim
  local stealth = mob.stealth_time or 0.08
  local ambush_delay = mob.ambush_delay or 0.12

  return fx.wait(stealth) >> function(_)
    if not World.alive(mob) then
      return Cont.unit("dead")
    end
    world.log("【AI·刺客】%s 隐入阴影…", mob.name)

    return fx.when_any({
      fx.wait_event("player_slash", function(p)
        return p and (p.id == mob.id or p.target_id == mob.id)
      end) >> function(_)
        return Cont.unit("broken")
      end,
      fx.wait(ambush_delay) >> function(_)
        return Cont.unit("ambush")
      end,
    }) >> function(winner)
      local v = winner and winner.value
      -- 先记账，再判断存活（击杀挥砍同帧会先扣 hp）
      if v == "broken" then
        world.checks.assassin_broken = true
        world.log("【AI·刺客】%s 潜行被识破，取消伏击！", mob.name)
        if not World.alive(mob) then
          return Cont.unit("dead")
        end
        return AI._assassin_basic_after(world, mob)
      end
      if v == "ambush" then
        local dmg = math.floor(mob.atk * 1.5 + 0.5)
        world.checks.assassin_ambush = true
        world.log("【AI·刺客】%s 伏击！dmg=%d（1.5×）", mob.name, dmg)
        if World.alive(mob) then
          sim:emit("mob_attack", { id = mob.id, name = mob.name, dmg = dmg, ambush = true })
        end
        if not World.alive(mob) then
          return Cont.unit("dead")
        end
        return fx.wait(mob.cooldown or 0.45) >> function(_)
          if not World.alive(mob) then
            return Cont.unit("dead")
          end
          return AI._assassin_basic_after(world, mob)
        end
      end
      if not World.alive(mob) then
        return Cont.unit("dead")
      end
      return AI._assassin_basic_after(world, mob)
    end
  end
end

function AI.make_assassin_ai(world, mob)
  return wrap_ai(world, mob, AI._assassin_loop)
end

------------------------------------------------------------
-- 启动：按 mob.ai / mob.kind 分发
------------------------------------------------------------

function AI.start(world, mob)
  local key = mob.ai or mob.kind or "basic"
  local pipe
  if key == "berserker" then
    pipe = AI.make_berserker_ai(world, mob)
  elseif key == "shaman" then
    pipe = AI.make_shaman_ai(world, mob)
  elseif key == "assassin" then
    pipe = AI.make_assassin_ai(world, mob)
  else
    -- normal / basic / boss / 默认 → 基础循环
    pipe = AI.make_mob_ai(world, mob)
  end
  local flow = world.sim:start_flow(mob.entity, pipe(nil))
  mob.ai_flow = flow
  return flow
end

return AI
