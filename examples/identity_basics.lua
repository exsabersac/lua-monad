#!/usr/bin/env lua
-- identity_basics.lua — Identity 单子最小演示
-- 在仓库根目录：lua examples/identity_basics.lua

package.path = "src/?.lua;" .. package.path

local Identity = require("identity")

print("=== Identity ===")

local r = Identity.unit(3) >> function(x)
  return Identity.unit(x + 4)
end
print("unit(3) >> (+4):", r.tag, Identity.runIdentity(r))

local s = Identity(10) >> function(x)
  return Identity(x * 2)
end
print("Identity(10) >> (*2):", Identity.runIdentity(s))

-- 顺序组合：丢弃左边
local t = Identity.unit("ignored") .. Identity.unit("kept")
print(".. discard left:", Identity.runIdentity(t))
