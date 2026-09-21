-- world.lua — 地牢突袭：世界状态、日志、实体辅助
-- 保持数值简单，控制流走 Cont/fx/GameSim。

local World = {}

--- 创建世界（含 GameSim、玩家、校验标志）
-- opts.quiet：少打印；opts.seed：仅记录（本 demo 确定性，不真随机）
function World.create(sim, opts)
  opts = opts or {}
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

  local world = {
    sim = sim,
    quiet = quiet,
    seed = opts.seed or 1,
    log = log,
    log_lines = log_lines,
    player = {
      name = "冒险者",
      hp = 120,
      max_hp = 120,
      atk = 40,
    },
    -- 校验用标志（assert / 测试读取）
    checks = {
      pause_deferred = false,
      mob_finally = false,
      chests_parallel = false,
      boss_path = nil, -- "interrupt" | "timeout"
      victory = false,
      -- 复杂 AI 标志（至少其一应在完整通关中为 true）
      berserker_enraged = false,
      shaman_interrupted = false,
      shaman_summoned = false,
      assassin_ambush = false,
      assassin_broken = false,
    },
    flags = {
      ready_for_pause = false,
      chests_t0 = nil,
      chests_t1 = nil,
    },
    -- mob_id → { finally_ran=bool, dropped=bool, ... }
    mob_meta = {},
    rooms_cleared = 0,
  }
  return world
end

function World.alive(unit)
  return unit and unit.hp and unit.hp > 0
end

function World.player_alive(world)
  return World.alive(world.player)
end

--- 生成一只怪：sim 实体 + 战斗数据
-- spec.ai： "basic"|"berserker"|"shaman"|"assassin"（优先于 kind 分发）
-- spec.kind： "normal"|"boss"（叙事/兼容）
function World.spawn_mob(world, spec)
  local sim = world.sim
  local ent = sim:spawn_entity(spec.name or "mob")
  local mob = {
    id = ent.id,
    entity = ent,
    name = spec.name or ("怪#" .. ent.id),
    hp = spec.hp or 30,
    max_hp = spec.hp or 30,
    atk = spec.atk or 8,
    windup = spec.windup or 0.35,
    cooldown = spec.cooldown or 0.55,
    kind = spec.kind or "normal", -- normal | boss
    ai = spec.ai, -- berserker | shaman | assassin | basic | nil→basic
    cast_time = spec.cast_time,
    heal_amount = spec.heal_amount,
    stealth_time = spec.stealth_time,
    ambush_delay = spec.ambush_delay,
  }
  world.mob_meta[mob.id] = {
    finally_ran = false,
    dropped = false,
    name = mob.name,
    ai = mob.ai,
  }
  world.log("生成 %s (id=%d hp=%d atk=%d ai=%s)",
    mob.name, mob.id, mob.hp, mob.atk, tostring(mob.ai or mob.kind or "basic"))
  return mob
end

function World.destroy_mob(world, mob, reason)
  if not mob or not mob.entity then
    return
  end
  local sim = world.sim
  if sim:get_entity(mob.entity.id) then
    world.log("摧毁 %s (%s)", mob.name, reason or "killed")
    sim:destroy_entity(mob.entity.id)
  end
  mob.hp = 0
end

return World
