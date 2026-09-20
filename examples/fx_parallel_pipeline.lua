#!/usr/bin/env lua
-- fx_parallel_pipeline.lua — C# 风格 async 方法：withEnv 步骤内 WhenAll 若干「拉取」再继续
-- 在仓库根目录执行：lua examples/fx_parallel_pipeline.lua
--
-- 对照示意（C#）：
--   async Task<Result> LoadAsync() {
--     var (a,b,c) = await Task.WhenAll(FetchA(), FetchB(), FetchC());
--     await Task.Delay(10);
--     return Combine(a,b,c);
--   }

package.path = "src/?.lua;" .. package.path

local Cont = require("cont")
local fx = require("fx")
local print, assert, tostring, ipairs, table = print, assert, tostring, ipairs, table

-- 模拟「异步拉取」：connect 到不同 host
local function fetch(name)
  return fx.connect(name) >> function(conn)
    return Cont.unit({ name = name, conn = conn })
  end
end

local pipeline = Cont.withEnv(function(_ENV)
  function prepare(_)
    print("  [step] prepare")
    return Cont.unit({ stage = "prep" })
  end

  -- 类似 async 方法体里的 await Task.WhenAll(...)
  function fetch_all(st)
    print("  [step] when_all(fetch a/b/c)")
    return fx.when_all({
      fetch("a"),
      fetch("b"),
      fetch("c"),
    }) >> function(parts)
      st.parts = parts
      return Cont.unit(st)
    end
  end

  function brief_pause(st)
    print("  [step] wait(0.02) after WhenAll")
    return fx.wait(0.02) >> function(_)
      st.paused = true
      return Cont.unit(st)
    end
  end

  function combine(st)
    print("  [step] combine")
    local names = {}
    for i, p in ipairs(st.parts) do
      names[i] = p.name
      assert(p.conn and p.conn.ok)
    end
    st.summary = table.concat(names, ",")
    st.stage = "done"
    return Cont.unit(st)
  end
end)

local handlers = {
  connect = function(req)
    print(string.format("  [handler] connect %s", tostring(req.host)))
    return { ok = true, host = req.host, latency = 0 }
  end,
  wait = function(req)
    -- 单任务路径；并行子任务 wait 由调度器处理
    local t0 = os.clock()
    while os.clock() - t0 < (req.seconds or 0) do end
    return true
  end,
}

print("=== parallel pipeline：WhenAll 三路 fetch 再继续 ===")
local t0 = os.clock()
local result = fx.run(pipeline(nil), handlers, { verbose_wait = true })
local elapsed = os.clock() - t0
assert(result.ok, "pipeline should ok")
local final = result.value
assert(final.stage == "done")
assert(final.summary == "a,b,c")
assert(final.paused == true)
assert(#final.parts == 3)
print(string.format("  summary=%s elapsed=%.3fs", final.summary, elapsed))

print("\nfx_parallel_pipeline OK")
