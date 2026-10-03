local source = debug.getinfo(1, "S").source
local plugin_dir = source:match("@(.+)/spec/[^/]+$") or "."
package.path = plugin_dir .. "/?.lua;" .. plugin_dir .. "/?/init.lua;" .. package.path

local scheduled = {}
local settings = {}

_G.G_reader_settings = {
    readSetting = function(_, key)
        if key == "home_dir" then return "/books" end
        return nil
    end,
}

package.preload["device"] = function()
    return {
        screen = {
            getWidth = function() return 540 end,
            getHeight = function() return 720 end,
            scaleBySize = function(_, value) return value end,
        },
    }
end

package.preload["datastorage"] = function()
    return { getSettingsDir = function() return "/tmp/koreader-settings" end }
end

package.preload["luasettings"] = function()
    return {
        open = function()
            return {
                readSetting = function(_, key) return settings[key] end,
                saveSetting = function(_, key, value) settings[key] = value end,
                flush = function() end,
            }
        end,
    }
end

local function widget_module()
    return {
        new = function(_, value) return value or {} end,
    }
end

package.preload["ui/widget/buttondialog"] = widget_module
package.preload["ui/widget/confirmbox"] = widget_module
package.preload["ui/widget/infomessage"] = widget_module
package.preload["ui/widget/inputdialog"] = widget_module
package.preload["ui/widget/pathchooser"] = widget_module
package.preload["ui/widget/qrmessage"] = widget_module
package.preload["ui/widget/textviewer"] = widget_module

package.preload["ui/uimanager"] = function()
    return {
        show = function() end,
        scheduleIn = function(_, delay, callback)
            table.insert(scheduled, { delay = delay, callback = callback })
        end,
        unschedule = function() end,
        nextTick = function(_, callback) callback() end,
    }
end

package.preload["ui/widget/container/widgetcontainer"] = function()
    local WidgetContainer = {}
    function WidgetContainer:extend(value)
        value.__index = value
        return value
    end
    return WidgetContainer
end

package.preload["gettext"] = function()
    return function(text) return text end
end

package.preload["ffi/util"] = function()
    return {
        template = function(text, ...)
            local values = { ... }
            for index, value in ipairs(values) do
                text = text:gsub("%%" .. tostring(index), tostring(value))
            end
            return text
        end,
    }
end

package.preload["util"] = function()
    return { makePath = function() return true end }
end

local log_events = {}
package.preload["diagnostic_log"] = function()
    return {
        init = function() return "/tmp/koreader-settings/send2ereader/logs/send2ereader-1.log" end,
        dir = function() return "/tmp/koreader-settings/send2ereader/logs" end,
        log = function(event, details)
            table.insert(log_events, tostring(event) .. " " .. tostring(details or ""))
            return true
        end,
        readCurrent = function() return "log" end,
        clear = function() return true end,
    }
end

local fake_client
package.preload["send2ereader/client"] = function()
    local Client = {}
    function Client:new(server_url, logger, plugin_version)
        fake_client = {
            base_url = server_url,
            plugin_version = plugin_version,
            createSession = function()
                return {
                    id = "session-1",
                    ownerToken = "x",
                    joinCode = "G7K2Q9",
                    expiresAt = "2099-01-01T00:00:00Z",
                }
            end,
            getCatalog = function()
                return {
                    itemCount = 2,
                    items = {
                        { id = "file-1", filename = "one.epub" },
                        { id = "file-2", filename = "two.pdf" },
                    },
                }
            end,
            joinUrl = function(_, code) return "https://send.example/#code=" .. code end,
            closeSession = function() return true end,
            setBaseUrl = function() return true end,
            probe = function() return { serverVersion = "0.1.0", allowedFileExtensions = {} } end,
        }
        return fake_client
    end
    function Client.normalizeBaseUrl(value) return value end
    function Client.basename(value) return value end
    return Client
end

package.loaded["main"] = nil
local Plugin = dofile(plugin_dir .. "/main.lua")
local registered
local opened_path
local instance = setmetatable({
    ui = {
        menu = {
            registerToMainMenu = function(_, plugin)
                registered = plugin
            end,
        },
        openFile = function(_, path)
            opened_path = path
        end,
    },
}, { __index = Plugin })

instance:init()
assert(instance.PLUGIN_VERSION == "0.1.1.1")
assert(type(instance.startSession) == "function")
assert(instance.startReceiveSession == nil)
assert(fake_client.plugin_version == instance.PLUGIN_VERSION)
assert(registered == instance)
assert(instance.settings_file == "/tmp/koreader-settings/send2ereader/send2ereader.lua")
assert(settings.server_url == "https://send.techy-notes.com")
assert(settings.destination == "/books")
assert(settings.browser_grid_columns == 3)
assert(settings.browser_grid_rows == 2)
assert(settings.browser_list_rows == 7)
assert(settings.browser_layout_defaults_v2 == true)

local menu = {}
instance:addToMainMenu(menu)
assert(menu.send2ereader)
assert(menu.send2ereader.sorting_hint == "tools")

assert(type(menu.send2ereader.callback) == "function")
assert(menu.send2ereader.sub_item_table == nil)

instance:setBrowserLayout(5, 4, 9, true)
assert(instance.browser_grid_columns == 5)
assert(instance.browser_grid_rows == 4)
assert(instance.browser_list_rows == 9)
assert(settings.browser_grid_columns == 5)
assert(settings.browser_grid_rows == 4)
assert(settings.browser_list_rows == 9)
instance:setBrowserLayout(3, 2, 7, true)

local session = instance:createOwnerSession(true)
assert(session)
assert(session.receiveMode == true)
assert(#scheduled >= 1)

local catalog = assert(instance:pollSessionCatalog(false))
assert(catalog.itemCount == 2)
assert(instance.catalog_seen_ids["file-1"])
assert(instance.catalog_seen_ids["file-2"])

local uploaded_local_path = "/books/already-local.epub"
assert(instance:rememberUploadedLocalFile({
    files = { { id = "uploaded-local", filename = "already-local.epub" } },
}, uploaded_local_path) == "uploaded-local")
assert(instance.downloaded_ids["uploaded-local"] == uploaded_local_path)

local downloaded_path = os.tmpname() .. ".epub"
local downloaded_file = assert(io.open(downloaded_path, "wb"))
downloaded_file:write("test")
downloaded_file:close()
instance.downloaded_ids["file-1"] = downloaded_path
instance:openDownloadedItem(catalog.items[1])
assert(opened_path == downloaded_path)
os.remove(downloaded_path)

print("plugin_state_test.lua: ok")
