-- world.lua — 护卫任务：世界状态、日志、实体辅助
-- 确定性数值，控制流走 Cont/fx/GameSim。

local World = {}

--- 创建世界
-- opts.quiet：少打印；opts.seed：仅记录
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
      name = "护卫队长",
      hp = 100,
      max_hp = 100,
      atk = 35,
    },
    escort = {
      name = "商队掌柜",
      hp = 60,
      max_hp = 60,
      pos = 0, -- 检查点索引 0..N
    },
    checkpoints = {
      { name = "西门", travel = 0.35 },
      { name = "河湾", travel = 0.45 },
      { name = "东驿", travel = 0.40 },
    },
    checks = {
      pause_deferred = false,
      enemy_finally = false,
      lanes_used = false,
      hud_proxy = false,
      checkpoint_chan = false,
      alert_chan = false,
      ambush_supervise_failed = false,
      ambush_supervised = false,
      rescue_ok = false,
      victory = false,
    },
    flags = {
      ready_for_pause = false,
      ambush_cleared = false,
      escort_arrived = false,
    },
    enemy_meta = {},
    arrived_count = 0,
  }
  return world
end

function World.alive(unit)
  return unit and unit.hp and unit.hp > 0
end

function World.player_alive(world)
  return World.alive(world.player)
end

function World.escort_alive(world)
  return World.alive(world.escort)
end

--- 生成伏击怪
function World.spawn_enemy(world, spec)
  local sim = world.sim
  local ent = sim:spawn_entity(spec.name or "ambush")
  local enemy = {
    id = ent.id,
    entity = ent,
    name = spec.name or ("伏击#" .. ent.id),
    hp = spec.hp or 40,
    max_hp = spec.hp or 40,
    atk = spec.atk or 8,
    windup = spec.windup or 0.25,
    cooldown = spec.cooldown or 0.40,
  }
  world.enemy_meta[enemy.id] = {
    finally_ran = false,
    name = enemy.name,
  }
  world.log("生成伏击 %s (id=%d hp=%d atk=%d)",
    enemy.name, enemy.id, enemy.hp, enemy.atk)
  return enemy
end

function World.destroy_enemy(world, enemy, reason)
  if not enemy or not enemy.entity then
    return
  end
  local sim = world.sim
  if sim:get_entity(enemy.entity.id) then
    world.log("摧毁 %s (%s)", enemy.name, reason or "killed")
    sim:destroy_entity(enemy.entity.id)
  end
  enemy.hp = 0
end

return World
