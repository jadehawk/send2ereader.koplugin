local Blitbuffer = require("ffi/blitbuffer")
local ButtonDialog = require("ui/widget/buttondialog")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InputContainer = require("ui/widget/container/inputcontainer")
local LeftContainer = require("ui/widget/container/leftcontainer")
local LineWidget = require("ui/widget/linewidget")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local TopContainer = require("ui/widget/container/topcontainer")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local _ = require("gettext")

local SettingsDialog = {}
local SettingsWidget = InputContainer:extend{
    name = "send2ereader_settings",
    covers_fullscreen = false,
}

local function clamp(value, minimum, maximum, fallback)
    value = tonumber(value) or fallback
    return math.max(minimum, math.min(maximum, value))
end

local function stateFromPlugin(plugin)
    return {
        grid_columns = clamp(plugin.browser_grid_columns, 2, 8, 3),
        grid_rows = clamp(plugin.browser_grid_rows, 1, 6, 2),
        list_rows = clamp(plugin.browser_list_rows, 4, 12, 7),
    }
end

local function copyState(state)
    return {
        grid_columns = state.grid_columns,
        grid_rows = state.grid_rows,
        list_rows = state.list_rows,
    }
end

local function sameState(a, b)
    return a.grid_columns == b.grid_columns
        and a.grid_rows == b.grid_rows
        and a.list_rows == b.list_rows
end

function SettingsWidget:init()
    self.section = self.section or "general"
    self.original = self.original or stateFromPlugin(self.plugin)
    self.values = self.values or copyState(self.original)

    local screen = Device.screen:getSize()
    self.screen_w = screen.w
    self.screen_h = screen.h
    self.scale = function(n) return Device.screen:scaleBySize(n) end
    self.border = Size.border.thin
    self.shell_border = Size.border.default
    self.divider_w = math.max(1, self.border)
    self.dialog_w = math.max(1, screen.w - math.max(self.scale(18), math.floor(screen.w * 0.07)))
    self.header_h = self.scale(30)
    local desired_body_h = self.scale(250)
    local max_dialog_h = math.max(1, screen.h - math.max(self.scale(24), math.floor(screen.h * 0.12)))
    self.dialog_h = math.min(max_dialog_h, self.header_h + desired_body_h + 2 * self.shell_border)
    self.dialog_inner_w = math.max(1, self.dialog_w - 2 * self.shell_border)
    self.dialog_inner_h = math.max(1, self.dialog_h - 2 * self.shell_border)
    self.body_h = math.max(1, self.dialog_inner_h - self.header_h)
    self.nav_w = math.max(self.scale(112), math.floor(self.dialog_inner_w * 0.27))
    self.nav_w = math.min(math.floor(self.dialog_inner_w * 0.33), self.nav_w)
    self.content_w = math.max(1, self.dialog_inner_w - self.nav_w - self.divider_w)
    self.page_pad = math.max(self.scale(7), math.floor(self.content_w * 0.025))
    self.content_inner_w = math.max(1, self.content_w - 2 * self.page_pad)
    self.dimen = Geom:new{ w = screen.w, h = screen.h }

    self:rebuild(false)
end

function SettingsWidget:requestRepaint(full)
    UIManager:setDirty(self, function()
        return full and "full" or "ui", self.dimen
    end)
end

function SettingsWidget:preview(state)
    self.plugin:setBrowserLayout(state.grid_columns, state.grid_rows, state.list_rows, false)
end

function SettingsWidget:closeAndRevert()
    self:preview(self.original)
    UIManager:close(self)
end

function SettingsWidget:onCloseWidget()
    if self.plugin and self.plugin.settings_dialog == self then
        self.plugin.settings_dialog = nil
    end
    UIManager:setDirty(nil, "full")
end

function SettingsWidget:tapFrame(text, width, height, opts, callback)
    opts = opts or {}
    local pad = opts.pad or self.scale(6)
    local bordersize = opts.bordersize or 0
    local frame_padding = opts.align == "left" and pad or 0
    local inner_w = math.max(1, width - 2 * (bordersize + frame_padding))
    local inner_h = math.max(1, height - 2 * (bordersize + frame_padding))
    local label

    if opts.wrap then
        label = TextBoxWidget:new{
            text = text,
            width = inner_w,
            height = inner_h,
            height_adjust = true,
            alignment = opts.align == "left" and "left" or "center",
            face = Font:getFace(opts.face or "cfont", opts.font_size or 15),
            bold = opts.bold == true,
            fgcolor = opts.fgcolor or Blitbuffer.COLOR_BLACK,
            height_overflow_show_ellipsis = true,
        }
    else
        label = TextWidget:new{
            text = text,
            face = Font:getFace(opts.face or "cfont", opts.font_size or 15),
            bold = opts.bold == true,
            fgcolor = opts.fgcolor or Blitbuffer.COLOR_BLACK,
            max_width = inner_w,
        }
    end

    local aligned = opts.align == "left"
        and LeftContainer:new{ dimen = Geom:new{ w = inner_w, h = inner_h }, label }
        or CenterContainer:new{ dimen = Geom:new{ w = inner_w, h = inner_h }, label }

    local frame = FrameContainer:new{
        width = width,
        height = height,
        margin = 0,
        padding = frame_padding,
        bordersize = bordersize,
        background = opts.background or Blitbuffer.COLOR_WHITE,
        radius = opts.radius or 0,
        aligned,
    }

    local item = InputContainer:new{
        dimen = Geom:new{ w = width, h = height },
        frame,
    }
    item.ges_events = {
        TapSelect = { GestureRange:new{ ges = "tap", range = item.dimen } },
    }
    item.onTapSelect = function()
        if callback then callback() end
        return true
    end
    return item
end

function SettingsWidget:actionButton(text, width, callback, primary, enabled)
    enabled = enabled ~= false
    return self:tapFrame(text, width, self.scale(33), {
        font_size = 14,
        bold = true,
        bordersize = self.border,
        background = enabled and (primary and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_WHITE)
            or Blitbuffer.COLOR_LIGHT_GRAY,
        fgcolor = enabled and (primary and Blitbuffer.COLOR_WHITE or Blitbuffer.COLOR_BLACK)
            or Blitbuffer.COLOR_DARK_GRAY,
        radius = self.scale(2),
    }, enabled and callback or nil)
end

function SettingsWidget:pageHeading(title, subtitle)
    local group = VerticalGroup:new{ align = "left" }
    table.insert(group, TextWidget:new{
        text = title,
        face = Font:getFace("cfont", 18),
        bold = true,
        max_width = self.content_inner_w,
    })
    if subtitle then
        table.insert(group, VerticalSpan:new{ width = self.scale(1) })
        table.insert(group, TextBoxWidget:new{
            text = subtitle,
            width = self.content_inner_w,
            height = self.scale(36),
            height_adjust = true,
            alignment = "left",
            face = Font:getFace("smallinfofont", 12),
            height_overflow_show_ellipsis = true,
        })
    end
    return group
end

function SettingsWidget:sectionHeading(text)
    return TextWidget:new{
        text = text,
        face = Font:getFace("cfont", 14),
        bold = true,
        max_width = self.content_inner_w,
    }
end

function SettingsWidget:contentFrame(group)
    return TopContainer:new{
        dimen = Geom:new{ w = self.content_w, h = self.body_h },
        FrameContainer:new{
            width = self.content_w,
            height = self.body_h,
            margin = 0,
            padding = self.page_pad,
            bordersize = 0,
            background = Blitbuffer.COLOR_WHITE,
            group,
        },
    }
end

function SettingsWidget:simplePage(title, subtitle, buttons)
    local group = VerticalGroup:new{ align = "left" }
    table.insert(group, self:pageHeading(title, subtitle))
    table.insert(group, VerticalSpan:new{ width = self.scale(18) })

    local button_w = math.min(
        self.content_inner_w,
        math.max(self.scale(180), math.floor(self.content_inner_w * 0.72))
    )

    for index, item in ipairs(buttons or {}) do
        table.insert(group, self:actionButton(item.text, button_w, item.callback, item.primary, item.enabled))
        if index < #(buttons or {}) then
            table.insert(group, VerticalSpan:new{ width = self.scale(8) })
        end
    end
    return self:contentFrame(group)
end

function SettingsWidget:chooseNumber(title, key, minimum, maximum)
    local picker
    local rows = {}
    local row = {}

    for number = minimum, maximum do
        local selected_number = number
        local text = number == self.values[key] and ("[" .. tostring(number) .. "]") or tostring(number)
        table.insert(row, {
            text = text,
            callback = function()
                UIManager:close(picker)
                local next_values = copyState(self.values)
                next_values[key] = selected_number
                self.values = next_values
                self:preview(next_values)
                UIManager:nextTick(function()
                    if self.plugin and self.plugin.settings_dialog == self then
                        self:rebuild(true)
                    end
                end)
            end,
        })
        if #row == 3 then
            table.insert(rows, row)
            row = {}
        end
    end

    if #row > 0 then table.insert(rows, row) end
    picker = ButtonDialog:new{
        title = title,
        title_align = "center",
        buttons = rows,
    }
    UIManager:show(picker)
end

function SettingsWidget:selector(value, title, key, minimum, maximum, width, height)
    return self:tapFrame(tostring(value), width, height, {
        font_size = 14,
        bordersize = self.border,
        background = Blitbuffer.COLOR_WHITE,
    }, function()
        self:chooseNumber(title, key, minimum, maximum)
    end)
end

function SettingsWidget:settingField(label_text, key, minimum, maximum, label_w, selector_w)
    local h = self.scale(30)
    return HorizontalGroup:new{
        align = "center",
        LeftContainer:new{
            dimen = Geom:new{ w = label_w, h = h },
            TextWidget:new{
                text = label_text,
                face = Font:getFace("smallinfofont", 13),
                max_width = math.max(1, label_w - self.scale(4)),
            },
        },
        self:selector(self.values[key], label_text, key, minimum, maximum, selector_w, h),
    }
end

function SettingsWidget:shelfPage()
    local top = VerticalGroup:new{ align = "left" }
    table.insert(top, self:pageHeading(
        _("Shelf Size (Items per page)"),
        _("Choose how many items to display in each view.")
    ))
    table.insert(top, VerticalSpan:new{ width = self.scale(4) })

    local selector_w = math.min(
        self.scale(54),
        math.max(self.scale(46), math.floor(self.content_inner_w * 0.13))
    )
    local first_label_w = math.max(self.scale(108), math.floor(self.content_inner_w * 0.34))
    local second_label_w = math.max(self.scale(46), math.floor(self.content_inner_w * 0.13))
    local field_gap = math.max(self.scale(28), math.floor(self.content_inner_w * 0.09))
    local row_w = first_label_w + selector_w + field_gap + second_label_w + selector_w
    if row_w > self.content_inner_w then
        field_gap = math.max(self.scale(14), field_gap - (row_w - self.content_inner_w))
    end

    table.insert(top, self:sectionHeading(_("Browser - Grid (Book Cards)")))
    table.insert(top, VerticalSpan:new{ width = self.scale(2) })
    table.insert(top, HorizontalGroup:new{
        align = "center",
        self:settingField(_("Columns:"), "grid_columns", 2, 8, first_label_w, selector_w),
        HorizontalSpan:new{ width = field_gap },
        self:settingField(_("Rows:"), "grid_rows", 1, 6, second_label_w, selector_w),
    })
    table.insert(top, VerticalSpan:new{ width = self.scale(6) })

    table.insert(top, self:sectionHeading(_("Browser - List (Book List)")))
    table.insert(top, VerticalSpan:new{ width = self.scale(2) })
    table.insert(top, self:settingField(_("Rows per page:"), "list_rows", 4, 12, first_label_w, selector_w))
    table.insert(top, VerticalSpan:new{ width = self.scale(6) })

    local footer_gap = math.max(self.scale(12), math.floor(self.content_inner_w * 0.035))
    local reset_w = math.max(self.scale(140), math.floor(self.content_inner_w * 0.40))
    local save_w = math.max(self.scale(82), math.floor(self.content_inner_w * 0.22))
    local save_enabled = not sameState(self.original, self.values)
    if reset_w + save_w + footer_gap > self.content_inner_w then
        reset_w = math.max(self.scale(132), math.floor((self.content_inner_w - footer_gap) * 0.62))
        save_w = math.max(1, self.content_inner_w - footer_gap - reset_w)
    end

    table.insert(top, CenterContainer:new{
        dimen = Geom:new{ w = self.content_inner_w, h = self.scale(33) },
        HorizontalGroup:new{
            align = "center",
            self:actionButton(_("Reset to Defaults"), reset_w, function()
                self.values = { grid_columns = 3, grid_rows = 2, list_rows = 7 }
                self:preview(self.values)
                self:rebuild(true)
            end, false),
            HorizontalSpan:new{ width = footer_gap },
            self:actionButton(_("Save"), save_w, function()
                self.plugin:setBrowserLayout(
                    self.values.grid_columns,
                    self.values.grid_rows,
                    self.values.list_rows,
                    true
                )
                self.original = copyState(self.values)
                self:rebuild(true)
            end, true, save_enabled),
        },
    })

    return self:contentFrame(top)
end

function SettingsWidget:serverPage()
    local group = VerticalGroup:new{ align = "left" }
    table.insert(group, self:pageHeading(
        _("Server"),
        _("Configure and test the Send2Ereader server connection.")
    ))
    table.insert(group, VerticalSpan:new{ width = self.scale(12) })

    local button_w = math.min(
        self.content_inner_w,
        math.max(self.scale(180), math.floor(self.content_inner_w * 0.72))
    )

    table.insert(group, self:actionButton(
        _("Server address:") .. "\n" .. tostring(self.plugin.server_url or ""),
        button_w,
        function()
            self.plugin:setServerUrl(function()
                if self.plugin and self.plugin.settings_dialog == self then
                    self.plugin.settings_server_status = nil
                    UIManager:nextTick(function()
                        if self.plugin and self.plugin.settings_dialog == self then
                            self:rebuild(true)
                        end
                    end)
                end
            end)
        end,
        false
    ))
    table.insert(group, VerticalSpan:new{ width = self.scale(8) })

    table.insert(group, self:actionButton(_("Test server connection"), button_w, function()
        self.plugin.settings_server_status = _("Testing connection...")
        self:rebuild(false)
        UIManager:nextTick(function()
            self.plugin:testServer(function(_ok, _payload, _err, summary)
                if self.plugin and self.plugin.settings_dialog == self then
                    self.plugin.settings_server_status = summary
                    self:rebuild(true)
                end
            end)
        end)
    end, true))

    if self.plugin.settings_server_status and self.plugin.settings_server_status ~= "" then
        table.insert(group, VerticalSpan:new{ width = self.scale(12) })
        table.insert(group, TextBoxWidget:new{
            text = tostring(self.plugin.settings_server_status),
            width = self.content_inner_w,
            height = self.scale(74),
            height_adjust = true,
            alignment = "left",
            face = Font:getFace("smallinfofont", 12),
            height_overflow_show_ellipsis = true,
        })
    end

    return self:contentFrame(group)
end

function SettingsWidget:buildPage()
    if self.section == "downloads" then
        return self:simplePage(_("Downloads"), _("Choose where received books are saved."), {
            {
                text = _("Download folder:") .. "\n" .. tostring(self.plugin.destination or ""),
                callback = function()
                    self.plugin:chooseDestination(function()
                        if self.plugin and self.plugin.settings_dialog == self then
                            UIManager:nextTick(function()
                                if self.plugin and self.plugin.settings_dialog == self then
                                    self:rebuild(true)
                                end
                            end)
                        end
                    end)
                end,
            },
        })
    elseif self.section == "server" then
        return self:serverPage()
    elseif self.section == "shelf" then
        return self:shelfPage()
    elseif self.section == "debug" then
        return self:simplePage(
            _("Debug"),
            _("Troubleshoot Send2Ereader settings and network activity."),
            {
                {
                    text = _("View current debug log"),
                    callback = function() self.plugin:showDebugLog() end,
                },
                {
                    text = _("Show settings and log paths"),
                    callback = function() self.plugin:showDebugPaths() end,
                },
                {
                    text = _("Clear debug logs"),
                    callback = function()
                        self.plugin:clearDebugLogs()
                        UIManager:nextTick(function()
                            if self.plugin and self.plugin.settings_dialog == self then
                                self:requestRepaint(true)
                            end
                        end)
                    end,
                },
            }
        )
    elseif self.section == "about" then
        return self:simplePage(
            _("About"),
            _("Send2Ereader") .. " v" .. tostring(self.plugin.PLUGIN_VERSION or "?"),
            {
                {
                    text = _("Check for Updates"),
                    callback = function()
                        require("send2ereader/updater").check(self.plugin)
                    end,
                },
            }
        )
    end

    self.section = "general"
    return self:simplePage(
        _("General"),
        _("Send2Ereader") .. " v" .. tostring(self.plugin.PLUGIN_VERSION or "?"),
        {
            {
                text = _("Downloads"),
                callback = function() self:switchSection("downloads") end,
            },
            {
                text = _("Server"),
                callback = function() self:switchSection("server") end,
            },
            {
                text = _("Shelf Size"),
                callback = function() self:switchSection("shelf") end,
            },
        }
    )
end

function SettingsWidget:navItems()
    return {
        { id = "general", text = _("General") },
        { id = "downloads", text = _("Downloads") },
        { id = "server", text = _("Server") },
        { id = "shelf", text = _("Shelf Size") },
        { id = "debug", text = _("Debug") },
        { id = "about", text = _("About") },
    }
end

function SettingsWidget:buildShell()
    local page = self:buildPage()
    local nav_items = self:navItems()
    local nav_row_h = self.scale(34)
    local nav_gap = 0

    if #nav_items > 1 then
        nav_gap = math.floor((self.body_h - nav_row_h * #nav_items - self.scale(8)) / (#nav_items - 1))
        nav_gap = math.max(0, math.min(self.scale(22), nav_gap))
    end

    local nav_used_h = nav_row_h * #nav_items + nav_gap * math.max(0, #nav_items - 1)
    local nav_top_pad = math.max(self.scale(4), math.floor((self.body_h - nav_used_h) / 2))
    local nav = VerticalGroup:new{ align = "left" }
    table.insert(nav, VerticalSpan:new{ width = nav_top_pad })

    for index, item in ipairs(nav_items) do
        local selected = item.id == self.section
        table.insert(nav, self:tapFrame(item.text, self.nav_w, nav_row_h, {
            align = "left",
            pad = self.scale(5),
            font_size = 15,
            bold = true,
            background = selected and Blitbuffer.COLOR_LIGHT_GRAY or Blitbuffer.COLOR_WHITE,
        }, function()
            if item.id ~= self.section then
                self:switchSection(item.id)
            end
        end))
        if index < #nav_items and nav_gap > 0 then
            table.insert(nav, VerticalSpan:new{ width = nav_gap })
        end
    end

    local nav_frame = TopContainer:new{
        dimen = Geom:new{ w = self.nav_w, h = self.body_h },
        nav,
    }

    local close_w = self.header_h
    local header_content_h = math.max(1, self.header_h - self.divider_w)
    local title_w = math.max(1, self.dialog_inner_w - 2 * close_w)
    local header = VerticalGroup:new{
        TopContainer:new{
            dimen = Geom:new{ w = self.dialog_inner_w, h = header_content_h },
            HorizontalGroup:new{
                align = "center",
                HorizontalSpan:new{ width = close_w },
                CenterContainer:new{
                    dimen = Geom:new{ w = title_w, h = header_content_h },
                    TextWidget:new{
                        text = _("Settings"),
                        face = Font:getFace("cfont", 15),
                        bold = true,
                        max_width = title_w,
                    },
                },
                self:tapFrame("X", close_w, header_content_h, {
                    font_size = 16,
                    bold = false,
                }, function() self:closeAndRevert() end),
            },
        },
        LineWidget:new{
            dimen = Geom:new{ w = self.dialog_inner_w, h = self.divider_w },
        },
    }

    return FrameContainer:new{
        width = self.dialog_w,
        height = self.dialog_h,
        margin = 0,
        padding = 0,
        bordersize = self.shell_border,
        background = Blitbuffer.COLOR_WHITE,
        VerticalGroup:new{
            align = "center",
            header,
            HorizontalGroup:new{
                align = "center",
                nav_frame,
                LineWidget:new{
                    dimen = Geom:new{ w = self.divider_w, h = self.body_h },
                },
                page,
            },
        },
    }
end

function SettingsWidget:rebuild(full_refresh)
    local centered = CenterContainer:new{
        dimen = Geom:new{ w = self.screen_w, h = self.screen_h },
        self:buildShell(),
    }

    if self[1] and self[1].free then
        self[1]:free()
    end
    self[1] = centered

    if self._shown then
        self:requestRepaint(full_refresh ~= false)
    end
end

function SettingsWidget:switchSection(section)
    if not section or section == self.section then return end
    self.section = section
    self:rebuild(true)
end

function SettingsWidget:show()
    self._shown = true
    UIManager:show(self)
    self:requestRepaint(true)
end

function SettingsDialog.show(plugin, section)
    if plugin.settings_dialog then
        local existing = plugin.settings_dialog
        if existing.switchSection then
            existing:switchSection(section or "general")
            return existing
        end
        pcall(function() UIManager:close(existing) end)
        plugin.settings_dialog = nil
    end

    local dialog = SettingsWidget:new{
        plugin = plugin,
        section = section or "general",
        original = stateFromPlugin(plugin),
    }
    plugin.settings_dialog = dialog
    dialog:show()
    return dialog
end

return SettingsDialog
