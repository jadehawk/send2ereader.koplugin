local source = debug.getinfo(1, "S").source
local plugin_dir = source:match("@(.+)/spec/[^/]+$") or "."
package.path = plugin_dir .. "/?.lua;" .. package.path

local root = "/tmp/send2ereader-diagnostic-log-test"
os.execute("rm -rf '" .. root .. "'")

package.loaded["datastorage"] = {
    getSettingsDir = function() return root end,
}
package.loaded["util"] = {
    makePath = function(path)
        return os.execute("mkdir -p '" .. path .. "'") == 0
    end,
}
package.loaded["diagnostic_log"] = nil

local DiagnosticLog = require("diagnostic_log")
local logs_dir = root .. "/send2ereader/logs"

assert(DiagnosticLog.init() == logs_dir .. "/send2ereader-1.log")
assert(DiagnosticLog.log("[network] response", "status=200 body={ok=true}"))

local handle = assert(io.open(logs_dir .. "/send2ereader-1.log", "r"))
local content = handle:read("*a")
handle:close()
assert(content:find("[network] response", 1, true))
assert(content:find("status=200", 1, true))

DiagnosticLog.init()
DiagnosticLog.init()
DiagnosticLog.init()
assert(io.open(logs_dir .. "/send2ereader-1.log", "r"))
assert(io.open(logs_dir .. "/send2ereader-2.log", "r"))
assert(io.open(logs_dir .. "/send2ereader-3.log", "r"))
assert(io.open(logs_dir .. "/send2ereader-4.log", "r") == nil)

DiagnosticLog.MAX_BYTES = 1
assert(DiagnosticLog.log("rotation-event"))
handle = assert(io.open(logs_dir .. "/send2ereader-1.log", "r"))
content = handle:read("*a")
handle:close()
assert(content:find("size-rotation", 1, true))
assert(content:find("rotation-event", 1, true))

assert(DiagnosticLog.clear())
handle = assert(io.open(logs_dir .. "/send2ereader-1.log", "r"))
content = handle:read("*a")
handle:close()
assert(content:find("manual-clear", 1, true))
assert(io.open(logs_dir .. "/send2ereader-2.log", "r") == nil)
assert(io.open(logs_dir .. "/send2ereader-3.log", "r") == nil)

local tail = assert(DiagnosticLog.readCurrent(1024))
assert(tail:find("manual-clear", 1, true))

os.execute("rm -rf '" .. root .. "'")
print("diagnostic_log_test.lua: ok")
