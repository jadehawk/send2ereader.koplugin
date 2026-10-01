local source = debug.getinfo(1, "S").source
local plugin_dir = source:match("@(.+)/spec/[^/]+$") or "."
package.path = plugin_dir .. "/?.lua;" .. plugin_dir .. "/?/init.lua;" .. package.path

local shown = {}

local function stub(name, value)
    package.preload[name] = function() return value or {} end
end

stub("ui/widget/confirmbox", {
    new = function(_, value) return value end,
})
stub("device", {})
stub("ui/widget/infomessage", {
    new = function(_, value) return value end,
})
stub("ui/network/manager", {
    isOnline = function() return true end,
    runWhenOnline = function(_, callback) return callback() end,
})
stub("ui/uimanager", {
    show = function(_, value) shown[#shown + 1] = value end,
    close = function() end,
    forceRePaint = function() end,
    quit = function() end,
})
stub("libs/libkoreader-lfs", {})
stub("ltn12", { sink = {} })
stub("rapidjson", {})
stub("ssl.https", {})
stub("gettext", function(text) return text end)

local Updater = require("send2ereader/updater")

assert(Updater.isNewer("0.1.1.2", "0.1.1") == true)
assert(Updater.isNewer("v0.1.1.2", "0.1.1") == true)
assert(Updater.isNewer("0.1.1", "0.1.1.0") == false)
assert(Updater.isNewer("0.1.1.0", "0.1.1") == false)
assert(Updater.isNewer("0.1.1.1", "0.1.1.2") == false)
assert(Updater.isNewer("0.1.2", "0.1.1.9") == true)
assert(Updater.isNewer("0.2.0", "0.1.99.99") == true)
assert(Updater.isNewer("0.1.1.2.3", "0.1.1") == false)
assert(Updater.isNewer("development", "0.1.1") == false)

local release = assert(Updater._releaseFromTable({
    tag_name = "v0.1.1.2",
    assets = {
        {
            name = "send2ereader.koplugin.zip",
            browser_download_url = "https://github.com/jadehawk/send2ereader.koplugin/releases/download/v0.1.1.2/send2ereader.koplugin.zip",
        },
    },
}))
assert(release.version == "0.1.1.2")
assert(Updater.isNewer(release.version, "0.1.1") == true)

local bad_release, bad_err = Updater._releaseFromTable({
    tag_name = "v0.1.1.2.3",
    assets = {},
})
assert(bad_release == nil)
assert(type(bad_err) == "string")

assert(Updater._trustedReleaseUrl(
    "https://github.com/jadehawk/send2ereader.koplugin/releases/download/v0.1.1.2/send2ereader.koplugin.zip"
) == true)
assert(Updater._trustedReleaseUrl("https://example.com/send2ereader.koplugin.zip") == false)
assert(Updater._safeArchivePath("send2ereader.koplugin/main.lua") == "send2ereader.koplugin/main.lua")
assert(Updater._safeArchivePath("../main.lua") == nil)
assert(Updater._safeArchivePath("/absolute/main.lua") == nil)

local accepted
Updater._installRelease = function(plugin, candidate)
    accepted = {
        plugin = plugin,
        version = candidate.version,
        url = candidate.url,
    }
end

local plugin = {
    PLUGIN_VERSION = "0.1.1",
    settings_store = {
        readSetting = function() return nil end,
        saveSetting = function() end,
        flush = function() end,
    },
}

Updater._latestRelease = function() return release end
Updater.check(plugin)
local prompt = shown[#shown]
assert(type(prompt) == "table")
assert(type(prompt.ok_callback) == "function")
assert(prompt.text:find("0.1.1.2", 1, true))
assert(prompt.text:find("0.1.1", 1, true))
prompt.ok_callback()
assert(accepted ~= nil)
assert(accepted.plugin == plugin)
assert(accepted.version == "0.1.1.2")
assert(accepted.url == release.url)

print("updater_test.lua: ok")
