-- fx_sched_drive_registry.lua — 未内建 kind：handlers / Registry / async
local Coro = require("coro")
local Registry = require("fx_registry")

local Mod = {}

function Mod.install(S)
  local H = S.drive_handlers

  -- 兜底：opts.handlers / Registry；async_kinds 时异步兑现
  function H.__registry(nursery, task, req)
    local handlers = nursery.handlers
    local opts = nursery.opts
    local handler = handlers[req.kind]
    if handler == nil then
      -- 再查全局注册表（handlers 合并遗漏时兜底）
      local ent = Registry.get(req.kind)
      if ent then
        handler = ent.handler
        local async_kinds = opts.async_kinds or handlers.__async_kinds or {}
        if ent.async then
          async_kinds = async_kinds or {}
          async_kinds[req.kind] = true
          opts.async_kinds = async_kinds
        end
      end
    end
    if handler == nil then
      local err = Registry.unknown_error(req.kind)
      S.emit_trace(opts, {
        type = "failed",
        task_id = task.id,
        error = err,
        kind = req.kind,
      })
      task.answer = Coro.Failed(err)
      return "failed"
    end
    S.emit_trace(opts, {
      type = "yield",
      task_id = task.id,
      kind = req.kind,
    })
    local async_kinds = opts.async_kinds or handlers.__async_kinds
    local is_async = async_kinds and async_kinds[req.kind]
    if is_async then
      local flag = { cancelled = false }
      task._timer_flag = flag -- 复用取消旗标（无 timer 时仅作 cancelled）
      task.waiting = true
      local kind_snapshot = req.kind
      handler(req, function(next_input)
        S.when_flow_active(opts, function()
          if flag.cancelled then
            return
          end
          if task.finished or not task.waiting then
            return
          end
          task.waiting = false
          task._timer_flag = nil
          S.emit_trace(opts, {
            type = "resume",
            task_id = task.id,
            kind = kind_snapshot,
          })
          task.answer = Coro.resume(task.answer, next_input)
          if type(opts._pump) == "function" then
            opts._pump()
          end
        end)
      end)
      return "wait"
    else
      local next_input = handler(req)
      S.emit_trace(opts, {
        type = "resume",
        task_id = task.id,
        kind = req.kind,
      })
      task.answer = Coro.resume(task.answer, next_input)
    end
  end
end

return Mod
