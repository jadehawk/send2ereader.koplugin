local Blitbuffer = require("ffi/blitbuffer")
local Button = require("ui/widget/button")
local Device = require("device")
local Font = require("ui/font")
local CenterContainer = require("ui/widget/container/centercontainer")
local FrameContainer = require("ui/widget/container/framecontainer")
local InputContainer = require("ui/widget/container/inputcontainer")
local LeftContainer = require("ui/widget/container/leftcontainer")
local LineWidget = require("ui/widget/linewidget")
local TopContainer = require("ui/widget/container/topcontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local IconWidget = require("ui/widget/iconwidget")
local ImageWidget = require("ui/widget/imagewidget")
local QRWidget = require("ui/widget/qrwidget")
local RenderImage = require("ui/renderimage")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local _ = require("gettext")

local Screen = Device.screen
local source_path = debug.getinfo(1, "S").source:gsub("^@", "")
local plugin_root = source_path:match("^(.*)[/\\]send2ereader[/\\]session_browser%.lua$")
local GRID_ICON_PATH = plugin_root and (plugin_root .. "/dependencies/icons/view-grid.svg") or nil
local LIST_ICON_PATH = plugin_root and (plugin_root .. "/dependencies/icons/view-list.svg") or nil
local REFRESH_ICON_PATH = plugin_root and (plugin_root .. "/dependencies/icons/refresh.svg") or nil
local SETTINGS_ICON_PATH = plugin_root and (plugin_root .. "/dependencies/icons/settings.svg") or nil
local CLOSE_ICON_PATH = plugin_root and (plugin_root .. "/dependencies/icons/close.svg") or nil
local PLACEHOLDER_COVER_PATH = plugin_root and (plugin_root .. "/dependencies/icons/placeholder-cover.svg") or nil
local BRAND_ICON_PATH = plugin_root and (plugin_root .. "/dependencies/icons/send2ereader-eink.png") or nil

local SessionBrowser = InputContainer:extend{
    name = "send2ereader_session_browser",
    covers_fullscreen = true,
}

local function safeText(value, limit)
    local text = tostring(value or ""):gsub("[%z\1-\31\127]", " "):gsub("%s+", " ")
    if not limit or #text <= limit then return text end
    return text:sub(1, math.max(1, limit - 3)) .. "..."
end

local function formatJoinCode(value)
    local normalized = tostring(value or ""):upper():gsub("%-", "")
    if #normalized == 6 and normalized:match("^[A-Z0-9]+$") then
        return normalized:sub(1, 3) .. "-" .. normalized:sub(4)
    end
    return safeText(value, 12)
end

local function utcEpoch(value)
    local year, month, day, hour, minute, second = tostring(value or ""):match(
        "^(%d%d%d%d)%-(%d%d)%-(%d%d)T(%d%d):(%d%d):(%d%d)"
    )
    if not year then return nil end

    local now = os.time()
    local local_now = os.date("*t", now)
    local utc_now = os.date("!*t", now)
    utc_now.isdst = local_now.isdst
    local utc_offset = os.difftime(os.time(local_now), os.time(utc_now))

    local parsed = {
        year = tonumber(year),
        month = tonumber(month),
        day = tonumber(day),
        hour = tonumber(hour),
        min = tonumber(minute),
        sec = tonumber(second),
        isdst = local_now.isdst,
    }
    local local_epoch = os.time(parsed)
    if not local_epoch then return nil end
    return local_epoch + utc_offset
end

local function remainingTimeText(expires_at)
    local expires_epoch = utcEpoch(expires_at)
    if not expires_epoch then return nil end
    local remaining = math.max(0, math.floor(os.difftime(expires_epoch, os.time())))
    local hours = math.floor(remaining / 3600)
    local minutes = math.floor((remaining % 3600) / 60)
    local seconds = remaining % 60
    if hours > 0 then
        return string.format("%d:%02d:%02d", hours, minutes, seconds)
    end
    return string.format("%02d:%02d", minutes, seconds)
end

local function tappableWidget(widget, width, height, callback)
    local item = InputContainer:new{
        dimen = Geom:new{ w = width, h = height },
        widget,
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

local function iconTap(icon, width, height, callback, icon_size)
    local size = icon_size or math.floor(height * 0.62)
    local icon_widget
    if type(icon) == "string" and (icon:find("/", 1, true) or icon:find("\\", 1, true)) then
        icon_widget = IconWidget:new{ file = icon, width = size, height = size }
    else
        icon_widget = IconWidget:new{ icon = icon, width = size, height = size }
    end
    local frame = FrameContainer:new{
        width = width,
        height = height,
        margin = 0,
        padding = 0,
        bordersize = 0,
        background = Blitbuffer.COLOR_WHITE,
        CenterContainer:new{
            dimen = Geom:new{ w = width, h = height },
            icon_widget,
        },
    }
    return tappableWidget(frame, width, height, callback)
end

local function actionButton(text, width, height, callback, opts)
    opts = opts or {}
    local label = TextWidget:new{
        text = text,
        face = Font:getFace("cfont", opts.font_size or 13),
        bold = opts.bold ~= false,
        fgcolor = opts.fgcolor or (opts.secondary and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_WHITE),
        max_width = math.max(1, width - 2 * Screen:scaleBySize(6)),
    }
    local frame = FrameContainer:new{
        width = width,
        height = height,
        margin = 0,
        padding = 0,
        bordersize = opts.secondary and Size.border.thin or 0,
        radius = Size.radius.button,
        background = opts.secondary and Blitbuffer.COLOR_WHITE or Blitbuffer.COLOR_BLACK,
        CenterContainer:new{ dimen = Geom:new{ w = width, h = height }, label },
    }
    return tappableWidget(frame, width, height, callback)
end

local function coverWidget(item, width, height, path)
    local border = Size.border.thin
    local inner_w = math.max(1, width - 2 * border)
    local inner_h = math.max(1, height - 2 * border)
    local image_path = path or PLACEHOLDER_COVER_PATH

    if image_path then
        local ok, scaled = pcall(function()
            if image_path == PLACEHOLDER_COVER_PATH then
                return RenderImage:renderSVGImageFile(image_path, inner_w, inner_h)
            end
            return RenderImage:renderImageFile(image_path, false, inner_w, inner_h)
        end)
        if ok and scaled then
            return FrameContainer:new{
                width = width,
                height = height,
                margin = 0,
                padding = 0,
                bordersize = border,
                background = Blitbuffer.COLOR_WHITE,
                ImageWidget:new{
                    image = scaled,
                    image_disposable = true,
                    scale_factor = 1,
                },
            }
        end
    end

    return FrameContainer:new{
        width = width,
        height = height,
        margin = 0,
        padding = 0,
        bordersize = border,
        background = Blitbuffer.COLOR_WHITE,
        CenterContainer:new{
            dimen = Geom:new{ w = inner_w, h = inner_h },
            IconWidget:new{
                icon = "document",
                width = math.max(1, math.floor(inner_w * 0.55)),
                height = math.max(1, math.floor(inner_w * 0.55)),
            },
        },
    }
end

function SessionBrowser:init()
    self.session = self.session or {}
    self.catalog = self.catalog or { items = {} }
    self.view_mode = self.view_mode == "list" and "list" or "grid"
    self.grid_columns = math.max(2, math.min(8, tonumber(self.grid_columns) or 3))
    self.grid_rows = math.max(1, math.min(6, tonumber(self.grid_rows) or 2))
    self.list_rows = math.max(4, math.min(12, tonumber(self.list_rows) or 7))
    self.page = 1
    self:updateItems()
end

function SessionBrowser:items()
    return (self.catalog and self.catalog.items) or {}
end

function SessionBrowser:gridColumns()
    return self.grid_columns
end

function SessionBrowser:gridRows()
    return self.grid_rows
end

function SessionBrowser:listRows()
    return self.list_rows
end

function SessionBrowser:setBrowserLayout(grid_columns, grid_rows, list_rows)
    self.grid_columns = math.max(2, math.min(8, tonumber(grid_columns) or 3))
    self.grid_rows = math.max(1, math.min(6, tonumber(grid_rows) or 2))
    self.list_rows = math.max(4, math.min(12, tonumber(list_rows) or 7))
    self.page = 1
    self:updateItems()
end

function SessionBrowser:itemsPerPage()
    if self.view_mode == "list" then return self:listRows() end
    return self:gridColumns() * self:gridRows()
end

function SessionBrowser:pageCount()
    return math.max(1, math.ceil(#self:items() / self:itemsPerPage()))
end

function SessionBrowser:pageBounds()
    local count = #self:items()
    local per_page = self:itemsPerPage()
    self.page = math.max(1, math.min(self.page, self:pageCount()))
    local first = (self.page - 1) * per_page + 1
    return first, math.min(count, first + per_page - 1)
end

function SessionBrowser:setPage(page)
    self.page = math.max(1, math.min(tonumber(page) or 1, self:pageCount()))
    self:updateItems()
end

function SessionBrowser:toggleView()
    self.view_mode = self.view_mode == "grid" and "list" or "grid"
    self.page = 1
    if self.plugin and self.plugin.setBrowserViewMode then
        self.plugin:setBrowserViewMode(self.view_mode)
    end
    self:updateItems()
end

function SessionBrowser:update(session, catalog)
    self.session = session or self.session or {}
    self.catalog = catalog or self.catalog or { items = {} }
    self.page = math.max(1, math.min(self.page, self:pageCount()))
    self:updateItems()
end

function SessionBrowser:onCloseWidget()
    if self.plugin and self.plugin.session_browser == self then
        self.plugin.session_browser = nil
    end
end

function SessionBrowser:headerWidget(width, height)
    local divider_h = math.max(1, Size.border.thin)
    local top_pad = Screen:scaleBySize(4)
    local row_h = math.max(1, height - top_pad - divider_h)
    local icon_w = row_h
    local title_w = math.max(1, width - 4 * icon_w)
    local title_pad = Screen:scaleBySize(8)
    local brand_icon_size = math.min(Screen:scaleBySize(28), math.max(1, row_h - Screen:scaleBySize(12)))
    local brand_gap = Screen:scaleBySize(6)
    local title_text_w = math.max(1, title_w - title_pad - brand_icon_size - brand_gap)
    local icon_size = math.min(Screen:scaleBySize(28), math.max(1, row_h - Screen:scaleBySize(10)))
    local row = HorizontalGroup:new{ align = "center" }

    local brand_icon
    if BRAND_ICON_PATH then
        local ok, scaled = pcall(function()
            return RenderImage:renderImageFile(BRAND_ICON_PATH, false, brand_icon_size, brand_icon_size)
        end)
        if ok and scaled then
            brand_icon = ImageWidget:new{
                image = scaled,
                image_disposable = true,
                scale_factor = 1,
            }
        end
    end
    if not brand_icon then
        brand_icon = IconWidget:new{
            icon = "document",
            width = brand_icon_size,
            height = brand_icon_size,
        }
    end

    table.insert(row, HorizontalGroup:new{
        align = "center",
        HorizontalSpan:new{ width = title_pad },
        CenterContainer:new{
            dimen = Geom:new{ w = brand_icon_size, h = row_h },
            brand_icon,
        },
        HorizontalSpan:new{ width = brand_gap },
        LeftContainer:new{
            dimen = Geom:new{ w = title_text_w, h = row_h },
            TextWidget:new{
                text = _("Send2Ereader"),
                face = Font:getFace("cfont", 20),
                bold = true,
                max_width = math.max(1, title_text_w - Screen:scaleBySize(4)),
            },
        },
    })
    table.insert(row, iconTap(REFRESH_ICON_PATH or "cre.render.reload", icon_w, row_h, function()
        if self.plugin and self.plugin.session then
            self.plugin:refreshSessionBrowser(true)
        end
    end, icon_size))
    table.insert(row, iconTap(SETTINGS_ICON_PATH or "appbar.settings", icon_w, row_h, function()
        if self.plugin and self.plugin.showBrowserSettings then self.plugin:showBrowserSettings() end
    end, icon_size))
    local toggle_icon = self.view_mode == "grid" and (LIST_ICON_PATH or "appbar.menu") or (GRID_ICON_PATH or "column.two")
    table.insert(row, iconTap(toggle_icon, icon_w, row_h, function() self:toggleView() end, icon_size))
    table.insert(row, iconTap(CLOSE_ICON_PATH or "close", icon_w, row_h, function()
        UIManager:close(self)
        if self.plugin then self.plugin.session_browser = nil end
    end, icon_size))

    return FrameContainer:new{
        width = width,
        height = height,
        margin = 0,
        padding = 0,
        bordersize = 0,
        background = Blitbuffer.COLOR_WHITE,
        VerticalGroup:new{
            VerticalSpan:new{ width = top_pad },
            row,
            LineWidget:new{
                dimen = Geom:new{ w = width, h = divider_h },
                background = Blitbuffer.COLOR_BLACK,
            },
        },
    }
end

function SessionBrowser:inactiveHero(width, height)
    local pad = Screen:scaleBySize(8)
    local inner_w = math.max(1, width - 2 * pad)
    local inner_h = math.max(1, height - 2 * pad)
    local button_gap = Screen:scaleBySize(7)
    local button_h = Screen:scaleBySize(32)
    local button_w = math.max(1, math.floor((inner_w - button_gap) / 2))

    local content = VerticalGroup:new{ align = "center" }
    table.insert(content, TextWidget:new{
        text = _("Send2Ereader"),
        face = Font:getFace("cfont", 19),
        bold = true,
        max_width = inner_w,
    })
    table.insert(content, VerticalSpan:new{ width = Screen:scaleBySize(3) })
    table.insert(content, TextWidget:new{
        text = _("Start or join a transfer session"),
        face = Font:getFace("smallinfofont", 13),
        max_width = inner_w,
    })
    table.insert(content, VerticalSpan:new{ width = Screen:scaleBySize(7) })

    local actions = HorizontalGroup:new{ align = "center" }
    table.insert(actions, actionButton(_("Start Session"), button_w, button_h, function()
        if self.plugin then self.plugin:startSession() end
    end))
    table.insert(actions, HorizontalSpan:new{ width = button_gap })
    table.insert(actions, actionButton(_("Join Session"), button_w, button_h, function()
        if self.plugin then self.plugin:joinSessionDialog() end
    end))

    table.insert(content, actions)
    return FrameContainer:new{
        width = width,
        height = height,
        margin = 0,
        padding = pad,
        bordersize = Size.border.thin,
        background = Blitbuffer.COLOR_WHITE,
        CenterContainer:new{
            dimen = Geom:new{ w = inner_w, h = inner_h },
            content,
        },
    }
end

function SessionBrowser:activeHero(width, height)
    local pad = Screen:scaleBySize(7)
    local inner_w = math.max(1, width - 2 * pad)
    local inner_h = math.max(1, height - 2 * pad)
    local session = self.session or {}
    local has_share_code = session.joinCode and session.joinCode ~= ""
    local join_url = has_share_code and self.plugin and self.plugin.client
        and self.plugin.client:joinUrl(session.joinCode) or nil
    local qr_size = has_share_code and math.min(inner_h, Screen:scaleBySize(105)) or 0
    local gap = has_share_code and Screen:scaleBySize(7) or 0
    local text_w = math.max(1, inner_w - qr_size - gap)

    local row = HorizontalGroup:new{ align = "center" }
    if has_share_code then
        table.insert(row, CenterContainer:new{
            dimen = Geom:new{ w = qr_size, h = inner_h },
            QRWidget:new{
                text = join_url,
                width = qr_size,
                height = qr_size,
            },
        })
        table.insert(row, HorizontalSpan:new{ width = gap })
    end

    local details = VerticalGroup:new{ align = "left" }
    table.insert(details, TextWidget:new{
        text = _("Session active"),
        face = Font:getFace("cfont", 16),
        bold = true,
        max_width = text_w,
    })
    if has_share_code then
        table.insert(details, TextWidget:new{
            text = formatJoinCode(session.joinCode),
            face = Font:getFace("cfont", 23),
            bold = true,
            max_width = text_w,
        })
        if join_url then
            table.insert(details, TextWidget:new{
                text = join_url,
                face = Font:getFace("smallinfofont", 10),
                max_width = text_w,
            })
        end
    else
        table.insert(details, TextWidget:new{
            text = _("Connected"),
            face = Font:getFace("cfont", 18),
            bold = true,
            max_width = text_w,
        })
    end

    local remaining = remainingTimeText(session.expiresAt)
    if remaining then
        table.insert(details, TextWidget:new{
            text = _("Time remaining") .. ": " .. remaining,
            face = Font:getFace("smallinfofont", 12),
            max_width = text_w,
        })
    end

    table.insert(details, VerticalSpan:new{ width = Screen:scaleBySize(3) })
    local button_gap = Screen:scaleBySize(5)
    local button_h = Screen:scaleBySize(30)
    local button_w = math.max(1, math.floor((text_w - 2 * button_gap) / 3))
    local actions = HorizontalGroup:new{ align = "center" }
    table.insert(actions, actionButton(_("Add Book"), button_w, button_h, function()
        if self.plugin then self.plugin:showSendOptions() end
    end, { font_size = 11 }))
    table.insert(actions, HorizontalSpan:new{ width = button_gap })
    table.insert(actions, actionButton(_("Download All"), button_w, button_h, function()
        if self.plugin then self.plugin:downloadReceived() end
    end, { font_size = 11 }))
    table.insert(actions, HorizontalSpan:new{ width = button_gap })
    local close_text = session.owner and _("End Session") or _("Leave Session")
    table.insert(actions, actionButton(close_text, button_w, button_h, function()
        if self.plugin then self.plugin:closeSession() end
    end, { font_size = 11, secondary = true }))
    table.insert(details, actions)

    table.insert(row, CenterContainer:new{
        dimen = Geom:new{ w = text_w, h = inner_h },
        LeftContainer:new{ dimen = Geom:new{ w = text_w, h = inner_h }, details },
    })

    return FrameContainer:new{
        width = width,
        height = height,
        margin = 0,
        padding = pad,
        bordersize = Size.border.thin,
        background = Blitbuffer.COLOR_WHITE,
        row,
    }
end

function SessionBrowser:heroWidget(width, height)
    if not self.session or not self.session.sessionId then
        return self:inactiveHero(width, height)
    end
    return self:activeHero(width, height)
end

function SessionBrowser:sectionHeaderWidget(width, height)
    return LeftContainer:new{
        dimen = Geom:new{ w = width, h = height },
        TextWidget:new{
            text = string.format(_("Ready on server (%d)"), #self:items()),
            face = Font:getFace("cfont", 16),
            bold = true,
            max_width = math.max(1, width - Screen:scaleBySize(16)),
        },
    }
end

function SessionBrowser:gridWidget(width, height)
    local items = self:items()
    if #items == 0 then
        return CenterContainer:new{
            dimen = Geom:new{ w = width, h = height },
            TextBoxWidget:new{
                text = self.session and self.session.sessionId
                    and _("No books are ready yet. Uploaded books will appear automatically.")
                    or _("Start or join a session to see books available for download."),
                width = math.max(1, width - Screen:scaleBySize(40)),
                alignment = "center",
                face = Font:getFace("infofont", 16),
            },
        }
    end

    local gap = Screen:scaleBySize(8)
    local info_h = Screen:scaleBySize(66)
    local cols = self:gridColumns()
    local rows = self:gridRows()
    local first, last = self:pageBounds()
    local cell_w = math.max(1, math.floor((width - (cols + 1) * gap) / cols))
    local cell_h = math.max(1, math.floor((height - (rows + 1) * gap) / rows))
    local grid = VerticalGroup:new{ align = "center" }
    local index = first

    local function bookCell(item)
        local cover_area_h = math.max(1, cell_h - info_h)
        local cover_w = math.max(1, math.min(cell_w - Screen:scaleBySize(4), math.floor(cover_area_h / 1.5)))
        local cover_h = math.max(1, math.min(cover_area_h, math.floor(cover_w * 1.5)))
        local path = self.plugin and self.plugin.coverPathForItem and self.plugin:coverPathForItem(item) or nil
        local downloaded = self.plugin and self.plugin.downloaded_ids and self.plugin.downloaded_ids[item.id]

        local card = VerticalGroup:new{ align = "center" }
        table.insert(card, coverWidget(item, cover_w, cover_h, path))
        table.insert(card, TextBoxWidget:new{
            text = safeText(item.title or item.filename or _("Untitled"), 72),
            width = cell_w,
            height = Screen:scaleBySize(22),
            alignment = "center",
            bold = true,
            face = Font:getFace("cfont", 12),
            height_overflow_show_ellipsis = true,
        })
        table.insert(card, TextBoxWidget:new{
            text = safeText(item.author or "", 48),
            width = cell_w,
            height = Screen:scaleBySize(15),
            alignment = "center",
            face = Font:getFace("x_smallinfofont", 10),
            height_overflow_show_ellipsis = true,
        })
        local download_w = math.max(Screen:scaleBySize(70), math.min(cell_w - Screen:scaleBySize(8), Screen:scaleBySize(108)))
        table.insert(card, actionButton(
            downloaded and _("Open") or _("Download"),
            download_w,
            Screen:scaleBySize(27),
            downloaded and function()
                if self.plugin and self.plugin.openDownloadedItem then self.plugin:openDownloadedItem(item) end
            end or function()
                if self.plugin and self.plugin.downloadCatalogItem then self.plugin:downloadCatalogItem(item) end
            end,
            { font_size = 11 }
        ))
        return CenterContainer:new{
            dimen = Geom:new{ w = cell_w, h = cell_h },
            card,
        }
    end

    for _ = 1, rows do
        table.insert(grid, VerticalSpan:new{ width = gap })
        local row = HorizontalGroup:new{ align = "center" }
        table.insert(row, HorizontalSpan:new{ width = gap })
        for _ = 1, cols do
            local item = items[index]
            if item and index <= last then
                table.insert(row, bookCell(item))
            else
                table.insert(row, HorizontalSpan:new{ width = cell_w })
            end
            table.insert(row, HorizontalSpan:new{ width = gap })
            index = index + 1
        end
        table.insert(grid, row)
    end
    return grid
end

function SessionBrowser:listWidget(width, height)
    local items = self:items()
    if #items == 0 then
        return CenterContainer:new{
            dimen = Geom:new{ w = width, h = height },
            TextBoxWidget:new{
                text = self.session and self.session.sessionId
                    and _("No books are ready yet. Uploaded books will appear automatically.")
                    or _("Start or join a session to see books available for download."),
                width = math.max(1, width - Screen:scaleBySize(40)),
                alignment = "center",
                face = Font:getFace("infofont", 16),
            },
        }
    end

    local rows = self:listRows()
    local first, last = self:pageBounds()
    local pad = Screen:scaleBySize(5)
    local row_h = math.max(1, math.floor(height / rows))
    local action_w = math.max(Screen:scaleBySize(86), math.floor(width * 0.20))
    local list = VerticalGroup:new{ align = "center" }

    local function appendRow(item)
        local cover_h = math.max(1, row_h - 2 * pad)
        local cover_w = math.max(1, math.floor(cover_h * 0.66))
        local meta_w = math.max(1, width - cover_w - action_w - 5 * pad)
        local path = self.plugin and self.plugin.coverPathForItem and self.plugin:coverPathForItem(item) or nil
        local downloaded = self.plugin and self.plugin.downloaded_ids and self.plugin.downloaded_ids[item.id]

        local meta = VerticalGroup:new{ align = "left" }
        table.insert(meta, TextWidget:new{
            text = safeText(item.title or item.filename or _("Untitled"), 120),
            face = Font:getFace("cfont", 17),
            bold = true,
            max_width = meta_w,
        })
        if item.author and tostring(item.author) ~= "" then
            table.insert(meta, TextWidget:new{
                text = safeText(item.author, 90),
                face = Font:getFace("smallinfofont", 13),
                max_width = meta_w,
            })
        end

        local row_content = HorizontalGroup:new{ align = "center" }
        table.insert(row_content, HorizontalSpan:new{ width = pad })
        table.insert(row_content, coverWidget(item, cover_w, cover_h, path))
        table.insert(row_content, HorizontalSpan:new{ width = 2 * pad })
        table.insert(row_content, CenterContainer:new{
            dimen = Geom:new{ w = meta_w, h = row_h },
            LeftContainer:new{ dimen = Geom:new{ w = meta_w, h = row_h }, meta },
        })
        table.insert(row_content, CenterContainer:new{
            dimen = Geom:new{ w = action_w, h = row_h },
            actionButton(
                downloaded and _("Open") or _("Download"),
                action_w - pad,
                math.min(Screen:scaleBySize(32), row_h - 2 * pad),
                downloaded and function()
                    if self.plugin and self.plugin.openDownloadedItem then self.plugin:openDownloadedItem(item) end
                end or function()
                    if self.plugin and self.plugin.downloadCatalogItem then self.plugin:downloadCatalogItem(item) end
                end,
                { font_size = 11 }
            ),
        })
        table.insert(row_content, HorizontalSpan:new{ width = pad })

        table.insert(list, FrameContainer:new{
            width = width,
            height = row_h,
            margin = 0,
            padding = 0,
            bordersize = Size.border.thin,
            color = Blitbuffer.COLOR_BLACK,
            background = Blitbuffer.COLOR_WHITE,
            row_content,
        })
    end

    for index = first, first + rows - 1 do
        local item = index <= last and items[index] or nil
        if item then
            appendRow(item)
        else
            table.insert(list, VerticalSpan:new{ width = row_h })
        end
    end
    return list
end

function SessionBrowser:footerWidget(width, height)
    local pages = self:pageCount()
    local current = math.max(1, math.min(self.page, pages))
    local can_back = current > 1
    local can_forward = current < pages
    local nav_w = math.max(Screen:scaleBySize(260), math.floor(width * 0.70))
    nav_w = math.min(width, nav_w)
    local icon_size = math.floor(height * 0.50)
    local function slot(ratio) return math.max(1, math.floor(nav_w * ratio)) end

    local first = Button:new{
        icon = "chevron.first",
        icon_width = icon_size,
        icon_height = icon_size,
        width = slot(0.17),
        enabled = can_back,
        callback = function() self:setPage(1) end,
        margin = 0,
        bordersize = 0,
        show_parent = self,
    }
    local prev = Button:new{
        icon = "chevron.left",
        icon_width = icon_size,
        icon_height = icon_size,
        width = slot(0.17),
        enabled = can_back,
        callback = function() self:setPage(current - 1) end,
        margin = 0,
        bordersize = 0,
        show_parent = self,
    }
    local page = Button:new{
        text = string.format(_("Page %d of %d"), current, pages),
        text_font_face = "cfont",
        text_font_size = 14,
        width = slot(0.32),
        margin = 0,
        bordersize = 0,
        show_parent = self,
    }
    local next_btn = Button:new{
        icon = "chevron.right",
        icon_width = icon_size,
        icon_height = icon_size,
        width = slot(0.17),
        enabled = can_forward,
        callback = function() self:setPage(current + 1) end,
        margin = 0,
        bordersize = 0,
        show_parent = self,
    }
    local last = Button:new{
        icon = "chevron.last",
        icon_width = icon_size,
        icon_height = icon_size,
        width = slot(0.17),
        enabled = can_forward,
        callback = function() self:setPage(pages) end,
        margin = 0,
        bordersize = 0,
        show_parent = self,
    }

    return FrameContainer:new{
        width = width,
        height = height,
        margin = 0,
        padding = 0,
        bordersize = 0,
        background = Blitbuffer.COLOR_WHITE,
        CenterContainer:new{
            dimen = Geom:new{ w = width, h = height },
            HorizontalGroup:new{ align = "center", first, prev, page, next_btn, last },
        },
    }
end

function SessionBrowser:updateItems()
    self.width = Screen:getWidth()
    self.height = Screen:getHeight()
    self.dimen = self.dimen or Geom:new{ w = self.width, h = self.height }
    self.dimen.w = self.width
    self.dimen.h = self.height

    local header_h = Screen:scaleBySize(50)
    local hero_h = math.max(Screen:scaleBySize(98), math.min(Screen:scaleBySize(135), math.floor(self.height * 0.17)))
    if self.session and self.session.sessionId then
        hero_h = math.max(hero_h, math.min(Screen:scaleBySize(150), math.floor(self.height * 0.20)))
    end
    local section_h = Screen:scaleBySize(30)
    local footer_h = Screen:scaleBySize(46)
    local content_h = math.max(Screen:scaleBySize(120), self.height - header_h - hero_h - section_h - footer_h)
    local shelf = self.view_mode == "list"
        and self:listWidget(self.width, content_h)
        or self:gridWidget(self.width, content_h)

    local shelf_frame = TopContainer:new{
        dimen = Geom:new{ w = self.width, h = content_h },
        shelf,
    }

    local content = VerticalGroup:new{
        align = "center",
        self:headerWidget(self.width, header_h),
        self:heroWidget(self.width, hero_h),
        self:sectionHeaderWidget(self.width, section_h),
        shelf_frame,
        self:footerWidget(self.width, footer_h),
    }
    local frame = FrameContainer:new{
        width = self.width,
        height = self.height,
        margin = 0,
        padding = 0,
        bordersize = 0,
        background = Blitbuffer.COLOR_WHITE,
        content,
    }

    if self[1] and self[1].free then self[1]:free() end
    self[1] = frame
    UIManager:setDirty(self, function()
        return "ui", self.dimen
    end)
end

return SessionBrowser
