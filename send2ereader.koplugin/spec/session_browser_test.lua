local source = debug.getinfo(1, "S").source
local plugin_dir = source:match("@(.+)/spec/[^/]+$") or "."

local handle = assert(io.open(plugin_dir .. "/send2ereader/session_browser.lua", "rb"))
local browser = handle:read("*a")
handle:close()

local function contains(text)
    return browser:find(text, 1, true) ~= nil
end

assert(contains('_("Start Session")'))
assert(contains('_("Join Session")'))
assert(contains('_("Add Book")'))
assert(contains('_("Download All")'))
assert(contains('_("End Session")'))
assert(contains('_("Leave Session")'))
assert(contains('text = join_url'))
assert(contains('self.plugin.client:joinUrl(session.joinCode)'))
assert(contains('math.floor(self.height * 0.20)'))
assert(contains('Screen:scaleBySize(150)'))
assert(not contains('_("Send/Upload")'))
assert(not contains('_("Receive")'))
assert(not contains('startReceiveSession'))

print("session_browser_test.lua: ok")
