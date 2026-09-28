local source = debug.getinfo(1, "S").source
local plugin_dir = source:match("@(.+)/spec/[^/]+$") or "."
package.path = plugin_dir .. "/?.lua;" .. plugin_dir .. "/?/init.lua;" .. package.path

local function widget_class()
    local class = {}
    class.__index = class

    function class:new(value)
        value = value or {}
        setmetatable(value, { __index = self })
        if value.init then value:init() end
        return value
    end

    function class:extend(value)
        value = value or {}
        value.__index = value
        setmetatable(value, { __index = self })
        function value:new(args)
            args = args or {}
            setmetatable(args, { __index = value })
            if args.init then args:init() end
            return args
        end
        return value
    end

    function class:free() end
    return class
end

local GenericWidget = widget_class()

package.preload["ffi/blitbuffer"] = function()
    return {
        COLOR_BLACK = 0,
        COLOR_WHITE = 255,
        COLOR_LIGHT_GRAY = 200,
        COLOR_DARK_GRAY = 80,
    }
end

package.preload["device"] = function()
    return {
        screen = {
            getSize = function() return { w = 540, h = 720 } end,
            scaleBySize = function(_, value) return value end,
        },
    }
end

package.preload["ui/font"] = function()
    return { getFace = function(_, name, size) return { name = name, size = size } end }
end

package.preload["ui/geometry"] = function()
    return { new = function(_, value) return value or {} end }
end

package.preload["ui/gesturerange"] = function()
    return { new = function(_, value) return value or {} end }
end

package.preload["ui/size"] = function()
    return { border = { thin = 1, default = 1 } }
end

package.preload["ui/uimanager"] = function()
    return {
        show = function() end,
        close = function() end,
        setDirty = function() end,
        nextTick = function(_, callback) callback() end,
    }
end

package.preload["gettext"] = function()
    return function(text) return text end
end

local generic_modules = {
    "ui/widget/buttondialog",
    "ui/widget/container/centercontainer",
    "ui/widget/container/framecontainer",
    "ui/widget/container/horizontalgroup",
    "ui/widget/container/inputcontainer",
    "ui/widget/container/leftcontainer",
    "ui/widget/container/topcontainer",
    "ui/widget/container/verticalgroup",
    "ui/widget/horizontalgroup",
    "ui/widget/horizontalspan",
    "ui/widget/linewidget",
    "ui/widget/textboxwidget",
    "ui/widget/textwidget",
    "ui/widget/verticalgroup",
    "ui/widget/verticalspan",
}

for _, name in ipairs(generic_modules) do
    package.preload[name] = function() return GenericWidget end
end

local SettingsDialog = require("send2ereader/settings_dialog")
local plugin = {
    browser_grid_columns = 3,
    browser_grid_rows = 2,
    browser_list_rows = 7,
    destination = "/books",
    server_url = "https://send.techy-notes.com",
    PLUGIN_VERSION = "0.1.0",
    setBrowserLayout = function() end,
}

local dialog = SettingsDialog.show(plugin, "general")
assert(dialog ~= nil)
assert(plugin.settings_dialog == dialog)
assert(dialog.section == "general")
assert(dialog[1] ~= nil)

dialog:switchSection("server")
assert(dialog.section == "server")
assert(dialog[1] ~= nil)

dialog:switchSection("shelf")
assert(dialog.section == "shelf")
assert(dialog[1] ~= nil)

print("settings_dialog_test.lua: ok")
