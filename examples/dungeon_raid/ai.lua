-- ai.lua — 怪物 AI：Cont.withEnv + init/finally + wait/emit 循环
-- destroy_entity 取消绑定 flow 时 finally 必跑（校验 cleanup / 掉落标志）

local Cont = require("cont")
local fx = require("fx")
local World = require("world")

local AI = {}

--- 构造一只怪的 AI Cont（绑定到 entity 后由 GameSim.start_flow 驱动）
-- withEnv：init 开仇恨 → hunt 循环；finally 记 cleanup
function AI.make_mob_ai(world, mob)
  local sim = world.sim
  local meta = world.mob_meta[mob.id]
  -- _ENV 作参数名时须捕获全局，否则查 env 得 nil
  local tostring = tostring

  return Cont.withEnv(function(_ENV)
    -- init：开启仇恨（普通步骤 a→b，自动 lift）
    function init(_)
      world.log("【AI·init】%s 进入仇恨", mob.name)
      return true
    end

    -- hunt：风摇 → 出招事件 → 冷却，直到实体被毁（cancel）
    function hunt(_)
      return AI._attack_loop(world, mob)
    end

    -- finally：任意退出（Done / Stopped / Failed）都清理
    function finally(outcome)
      meta.finally_ran = true
      meta.dropped = true
      meta.outcome = outcome.status
      meta.reason = outcome.reason or outcome.error
      world.checks.mob_finally = true
      world.log("【AI·finally】%s status=%s reason=%s → 掉落标记",
        mob.name, tostring(outcome.status), tostring(meta.reason))
      return Cont.unit(true)
    end
  end)
end

--- 攻击循环（Cont 递归）；实体销毁时 wait 被 cancel，不会继续
function AI._attack_loop(world, mob)
  local sim = world.sim
  return fx.wait(mob.windup) >> function(_)
    if not World.alive(mob) then
      return Cont.unit("dead")
    end
    -- 出招：派发 mob_attack，供玩家 wait_event 接住
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

--- 启动 mob AI flow，绑定实体
function AI.start(world, mob)
  local pipe = AI.make_mob_ai(world, mob)
  local flow = world.sim:start_flow(mob.entity, pipe(nil))
  mob.ai_flow = flow
  return flow
end

return AI
