#!/usr/bin/env lua
-- writer_log.lua — Writer：tell + bind 链累积字符串日志
-- 在仓库根目录：lua examples/writer_log.lua

package.path = "src/?.lua;" .. package.path

local Writer = require("writer")

print("=== Writer（默认 string 日志）===")

local prog = Writer.tell("start;") >> function()
  return Writer.unit(1) >> function(x)
    return Writer.tell("got " .. tostring(x) .. ";") .. Writer.unit(x + 1) >> function(y)
      return Writer.tell("end=" .. tostring(y) .. ";") .. Writer.unit(y)
    end
  end
end

local v, log = Writer.runWriter(prog)
print("value:", v)
print("log:  ", log)

-- listen：同时拿到当前累计 log
local listened = Writer.listen(
  Writer.tell("a") .. Writer.tell("b") .. Writer.unit(42)
)
local lv, ll = Writer.runWriter(listened)
print("listen value.value=", lv.value, "value.log=", lv.log, "outer log=", ll)

print("\n=== WriterList（表列表 monoid）===")
local WL = Writer.WriterList
local list_prog = WL.tell({ "step1" }) >> function()
  return WL.tell({ "step2", "step3" }) .. WL.unit("ok")
end
local lv2, llog = WL.runWriter(list_prog)
print("value:", lv2)
io.write("log:  { ")
for i, s in ipairs(llog) do
  io.write(string.format("%q%s", s, i < #llog and ", " or ""))
end
print(" }")
