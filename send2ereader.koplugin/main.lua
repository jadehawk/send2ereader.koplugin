local source = debug.getinfo(1, "S").source or ""
local source_path = source:gsub("^@", "")
local plugin_root = assert(source_path:match("^(.*)[/\\]main%.lua$"), "Unable to determine Send2Ereader plugin root")

local Device = require("device")
local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")
local ButtonDialog = require("ui/widget/buttondialog")
local ConfirmBox = require("ui/widget/confirmbox")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local PathChooser = require("ui/widget/pathchooser")
local QRMessage = require("ui/widget/qrmessage")
local TextViewer = require("ui/widget/textviewer")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local Client = require("send2ereader/client")
local DiagnosticLog = require("diagnostic_log")
local _ = require("gettext")
local T = require("ffi/util").template
local util = require("util")

local DEFAULT_SERVER = "https://send.techy-notes.com"
local PluginMeta = dofile(plugin_root .. "/_meta.lua")
local VERSION = assert(PluginMeta.version, "Missing plugin version in _meta.lua")
local CATALOG_POLL_SECONDS = 4

local Send2Ereader = WidgetContainer:extend{
    name = "send2ereader",
    is_doc_only = false,
}
Send2Ereader.PLUGIN_VERSION = VERSION

local function display_error(err)
    return tostring(err or _("Unknown error"))
end

local function count_table(tbl)
    local count = 0
    for _ in pairs(tbl or {}) do count = count + 1 end
    return count
end

local function clamp(value, minimum, maximum, fallback)
    value = tonumber(value) or fallback
    return math.max(minimum, math.min(maximum, value))
end

function Send2Ereader:init()
    DiagnosticLog.init()
    DiagnosticLog.log("[plugin] init:start", "version=" .. VERSION)
    self.path = self.path or plugin_root

    local settings_dir = DataStorage:getSettingsDir() .. "/send2ereader"
    util.makePath(settings_dir)
    self.settings_dir = settings_dir
    self.settings_file = settings_dir .. "/send2ereader.lua"
    self.cover_cache_dir = settings_dir .. "/covers"
    util.makePath(self.cover_cache_dir)
    self.settings_store = LuaSettings:open(self.settings_file)

    local legacy_server = G_reader_settings:readSetting("send2ereader_server_url")
    local legacy_destination = G_reader_settings:readSetting("send2ereader_destination")
    self.server_url = self.settings_store:readSetting("server_url") or legacy_server or DEFAULT_SERVER
    self.destination = self.settings_store:readSetting("destination")
        or legacy_destination
        or G_reader_settings:readSetting("home_dir")
        or "."
    self.browser_view_mode = self.settings_store:readSetting("browser_view_mode") == "list" and "list" or "grid"
    local stored_grid_columns = self.settings_store:readSetting("browser_grid_columns")
    local stored_grid_rows = self.settings_store:readSetting("browser_grid_rows")
    local defaults_v2 = self.settings_store:readSetting("browser_layout_defaults_v2")
    if not defaults_v2 and tonumber(stored_grid_columns) == 4 and tonumber(stored_grid_rows) == 3 then
        stored_grid_columns = 3
        stored_grid_rows = 2
    end
    self.browser_grid_columns = clamp(stored_grid_columns, 2, 8, 3)
    self.browser_grid_rows = clamp(stored_grid_rows, 1, 6, 2)
    self.browser_list_rows = clamp(self.settings_store:readSetting("browser_list_rows"), 4, 12, 7)

    if not self.settings_store:readSetting("server_url") then
        self.settings_store:saveSetting("server_url", self.server_url)
    end
    if not self.settings_store:readSetting("destination") then
        self.settings_store:saveSetting("destination", self.destination)
    end
    if not self.settings_store:readSetting("browser_view_mode") then
        self.settings_store:saveSetting("browser_view_mode", self.browser_view_mode)
    end
    if not self.settings_store:readSetting("browser_grid_columns") then
        self.settings_store:saveSetting("browser_grid_columns", self.browser_grid_columns)
    end
    if not self.settings_store:readSetting("browser_grid_rows") then
        self.settings_store:saveSetting("browser_grid_rows", self.browser_grid_rows)
    end
    if not self.settings_store:readSetting("browser_list_rows") then
        self.settings_store:saveSetting("browser_list_rows", self.browser_list_rows)
    end
    self.settings_store:saveSetting("browser_grid_columns", self.browser_grid_columns)
    self.settings_store:saveSetting("browser_grid_rows", self.browser_grid_rows)
    self.settings_store:saveSetting("browser_layout_defaults_v2", true)
    self.settings_store:flush()

    self.client = assert(Client:new(self.server_url, function(event, details)
        DiagnosticLog.log(event, details)
    end, VERSION))
    self.session = nil
    self.catalog = { items = {} }
    self.downloaded_ids = {}
    self.catalog_seen_ids = {}
    self.cover_attempted_ids = {}
    self.session_browser = nil
    self.session_poll_callback = nil

    self.ui.menu:registerToMainMenu(self)
    UIManager:scheduleIn(1, function()
        local ok, updater = pcall(require, "send2ereader/updater")
        if ok and updater and updater.checkAutomatic then
            updater.checkAutomatic(self)
        end
    end)
    DiagnosticLog.log("[plugin] init:complete",
        "settings=" .. self.settings_file
        .. " logs=" .. tostring(DiagnosticLog.dir() or "")
        .. " server=" .. self.server_url
        .. " destination=" .. self.destination)
end

function Send2Ereader:saveSetting(name, value)
    self.settings_store:saveSetting(name, value)
    self.settings_store:flush()
    DiagnosticLog.log("[settings] saved", "key=" .. tostring(name))
end

function Send2Ereader:showMessage(text, timeout)
    UIManager:show(InfoMessage:new{
        text = text,
        timeout = timeout,
    })
end

local function file_exists(path)
    if not path or path == "" then return false end
    local file = io.open(path, "rb")
    if not file then return false end
    file:close()
    return true
end

function Send2Ereader:setBrowserViewMode(mode)
    self.browser_view_mode = mode == "list" and "list" or "grid"
    self:saveSetting("browser_view_mode", self.browser_view_mode)
end

function Send2Ereader:setBrowserLayout(grid_columns, grid_rows, list_rows, persist)
    self.browser_grid_columns = clamp(grid_columns, 2, 8, 3)
    self.browser_grid_rows = clamp(grid_rows, 1, 6, 2)
    self.browser_list_rows = clamp(list_rows, 4, 12, 7)

    if persist then
        self.settings_store:saveSetting("browser_grid_columns", self.browser_grid_columns)
        self.settings_store:saveSetting("browser_grid_rows", self.browser_grid_rows)
        self.settings_store:saveSetting("browser_list_rows", self.browser_list_rows)
        self.settings_store:flush()
        DiagnosticLog.log("[settings] browser-layout:saved",
            "grid=" .. tostring(self.browser_grid_columns) .. "x" .. tostring(self.browser_grid_rows)
            .. " list_rows=" .. tostring(self.browser_list_rows))
    end

    if self.session_browser and self.session_browser.setBrowserLayout then
        self.session_browser:setBrowserLayout(
            self.browser_grid_columns,
            self.browser_grid_rows,
            self.browser_list_rows
        )
    end
end

function Send2Ereader:showLayoutSettings()
    DiagnosticLog.log("[ui] settings:open", "section=shelf")
    require("send2ereader/settings_dialog").show(self, "shelf")
end

function Send2Ereader:showBrowserSettings()
    DiagnosticLog.log("[ui] settings:open", "section=general")
    require("send2ereader/settings_dialog").show(self, "general")
end

function Send2Ereader:coverCachePath(item)
    if not item or not item.id or not item.coverPath then return nil end
    local media_type = tostring(item.coverMediaType or ""):lower()
    local extension = "img"
    if media_type == "image/jpeg" then
        extension = "jpg"
    elseif media_type == "image/png" then
        extension = "png"
    elseif media_type == "image/gif" then
        extension = "gif"
    elseif media_type == "image/webp" then
        extension = "webp"
    elseif media_type == "image/svg+xml" then
        extension = "svg"
    end
    local id = tostring(item.id):gsub("[^%w%-_]", "_")
    return self.cover_cache_dir .. "/" .. id .. "." .. extension
end

function Send2Ereader:coverPathForItem(item)
    local path = self:coverCachePath(item)
    if path and file_exists(path) then return path end
    return nil
end

function Send2Ereader:cacheCatalogCovers(items)
    local session = self.session
    if not session then return end

    for _, item in ipairs(items or {}) do
        if item.id and item.coverPath and not self:coverPathForItem(item) and not self.cover_attempted_ids[item.id] then
            self.cover_attempted_ids[item.id] = true
            local destination = self:coverCachePath(item)
            local cached, err = self.client:downloadAsset(item.coverPath, session.capability, destination)
            if cached then
                DiagnosticLog.log("[catalog] cover:cached",
                    "file=" .. tostring(item.id) .. " path=" .. tostring(cached))
            else
                DiagnosticLog.log("[catalog] cover:failed",
                    "file=" .. tostring(item.id) .. " error=" .. tostring(err or "unknown"))
            end
        end
    end
end

function Send2Ereader:stopCatalogPolling()
    if self.session_poll_callback then
        UIManager:unschedule(self.session_poll_callback)
        self.session_poll_callback = nil
        DiagnosticLog.log("[catalog] polling:stopped")
    end
end

function Send2Ereader:startCatalogPolling()
    self:stopCatalogPolling()
    if not self.session or not self.session.receiveMode then return end

    local callback
    callback = function()
        if self.session and self.session.receiveMode then
            self:pollSessionCatalog(false)
            if self.session and self.session.receiveMode then
                UIManager:scheduleIn(CATALOG_POLL_SECONDS, callback)
            end
        end
    end
    self.session_poll_callback = callback
    UIManager:scheduleIn(1, callback)
    DiagnosticLog.log("[catalog] polling:started",
        "session=" .. tostring(self.session.sessionId)
        .. " interval_seconds=" .. tostring(CATALOG_POLL_SECONDS))
end

function Send2Ereader:setSession(session)
    self:stopCatalogPolling()
    if self.session_browser then
        pcall(function() UIManager:close(self.session_browser) end)
        self.session_browser = nil
    end
    self.session = session
    self.catalog = { items = {} }
    self.downloaded_ids = {}
    self.catalog_seen_ids = {}
    self.cover_attempted_ids = {}
    if session then
        DiagnosticLog.log("[session] active",
            "id=" .. tostring(session.sessionId)
            .. " owner=" .. tostring(session.owner == true)
            .. " receive_mode=" .. tostring(session.receiveMode == true)
            .. " join_code=" .. tostring(session.joinCode or ""))
        if session.receiveMode then
            self:startCatalogPolling()
        end
    else
        DiagnosticLog.log("[session] cleared")
    end
end

function Send2Ereader:currentBookPath()
    return self.ui and self.ui.document and self.ui.document.file
end

function Send2Ereader:createOwnerSession(receive_mode)
    DiagnosticLog.log("[session] create:start", "receive_mode=" .. tostring(receive_mode == true))
    local created, err = self.client:createSession()
    if not created then
        DiagnosticLog.log("[session] create:failed", tostring(err or "unknown"))
        self:showMessage(T(_("Could not create a transfer session.\n\n%1"), display_error(err)))
        return nil
    end
    local session = {
        sessionId = created.id,
        capability = created.ownerToken,
        owner = true,
        joinCode = created.joinCode,
        expiresAt = created.expiresAt,
        receiveMode = receive_mode == true,
    }
    self:setSession(session)
    DiagnosticLog.log("[session] create:complete",
        "id=" .. tostring(created.id) .. " join_code=" .. tostring(created.joinCode or ""))
    return session
end

function Send2Ereader:showSessionInfo(prefix)
    if not self.session then
        self:showMessage(_("No active Send2Ereader session."))
        return
    end

    local lines = {}
    if prefix and prefix ~= "" then
        table.insert(lines, prefix)
        table.insert(lines, "")
    end
    if self.session.joinCode then
        table.insert(lines, T(_("Join code: %1"), self.session.joinCode))
    else
        table.insert(lines, _("Joined another device's session."))
    end
    table.insert(lines, T(_("Server: %1"), self.server_url))
    table.insert(lines, T(_("Download folder: %1"), self.destination))
    table.insert(lines, T(_("Detected files: %1"), count_table(self.catalog_seen_ids)))
    if self.session.expiresAt then
        table.insert(lines, T(_("Expires: %1"), tostring(self.session.expiresAt)))
    end
    self:showMessage(table.concat(lines, "\n"))
end

function Send2Ereader:showSessionQr(after_text)
    if not self.session or not self.session.joinCode then
        self:showMessage(_("No shareable session code is available."))
        return
    end

    local Screen = Device.screen
    local size = math.min(Screen:getWidth(), Screen:getHeight()) - Screen:scaleBySize(48)
    UIManager:show(QRMessage:new{
        text = self.client:joinUrl(self.session.joinCode),
        width = size,
        height = size,
        dismiss_callback = function()
            self:showSessionInfo(after_text)
        end,
    })
end

function Send2Ereader:openDashboard()
    if self.session_browser then
        pcall(function() UIManager:close(self.session_browser) end)
        self.session_browser = nil
    end

    if self.session then
        self.session.receiveMode = true
        self:startCatalogPolling()
    end

    local SessionBrowser = require("send2ereader/session_browser")
    self.session_browser = SessionBrowser:new{
        plugin = self,
        session = self.session or {},
        catalog = self.catalog or { items = {} },
        view_mode = self.browser_view_mode,
        grid_columns = self.browser_grid_columns,
        grid_rows = self.browser_grid_rows,
        list_rows = self.browser_list_rows,
    }
    UIManager:show(self.session_browser)
    if self.session then self:refreshSessionBrowser(false) end
end

function Send2Ereader:openSessionBrowser()
    self:openDashboard()
end

function Send2Ereader:startReceiveSession()
    local session = self.session
    if not session then
        session = self:createOwnerSession(true)
        if not session then return end
    elseif session.owner and not session.receiveMode then
        session.receiveMode = true
        self:startCatalogPolling()
    end

    DiagnosticLog.log("[receive] session:ready", "id=" .. tostring(session.sessionId))
    self:openDashboard()
end

function Send2Ereader:ensureSession()
    if self.session then
        return self.session, false
    end
    local session = self:createOwnerSession(false)
    return session, session ~= nil
end

function Send2Ereader:rememberUploadedLocalFile(uploaded, file_path)
    local uploaded_file = type(uploaded) == "table"
        and type(uploaded.files) == "table"
        and uploaded.files[1]
        or nil
    if not uploaded_file or not uploaded_file.id or not file_path or file_path == "" then
        return nil
    end
    self.downloaded_ids[uploaded_file.id] = file_path
    DiagnosticLog.log("[upload] local-map",
        "file=" .. tostring(uploaded_file.id) .. " path=" .. tostring(file_path))
    return uploaded_file.id
end

function Send2Ereader:sendFile(file_path)
    if not file_path or file_path == "" then
        self:showMessage(_("No file was selected."))
        return
    end

    local session, created_now = self:ensureSession()
    if not session then return end

    DiagnosticLog.log("[upload] ui:start",
        "session=" .. tostring(session.sessionId) .. " path=" .. tostring(file_path))
    local uploaded, err = self.client:uploadFile(session.sessionId, session.capability, file_path)
    if not uploaded then
        DiagnosticLog.log("[upload] ui:failed",
            "session=" .. tostring(session.sessionId) .. " error=" .. tostring(err or "unknown"))
        if created_now and session.owner then
            pcall(function()
                self.client:closeSession(session.sessionId, session.capability)
            end)
            self:setSession(nil)
        end
        self:showMessage(T(_("Upload failed for %1.\n\n%2"), Client.basename(file_path), display_error(err)))
        return
    end

    DiagnosticLog.log("[upload] ui:complete",
        "session=" .. tostring(session.sessionId)
        .. " filename=" .. Client.basename(file_path)
        .. " server_file_count=" .. tostring(type(uploaded.files) == "table" and #uploaded.files or 0))

    self:rememberUploadedLocalFile(uploaded, file_path)

    session.receiveMode = true
    self:startCatalogPolling()
    self:pollSessionCatalog(false)
    self:openDashboard()
    self:showMessage(T(_("Uploaded: %1"), Client.basename(file_path)), 3)
end

function Send2Ereader:sendCurrentBook()
    local file_path = self:currentBookPath()
    if not file_path then
        self:showMessage(_("No book is currently open."))
        return
    end
    self:sendFile(file_path)
end

function Send2Ereader:showSendOptions()
    local dialog
    local buttons = {}
    if self:currentBookPath() then
        table.insert(buttons, {
            {
                text = _("Send current book"),
                callback = function()
                    UIManager:close(dialog)
                    self:sendCurrentBook()
                end,
            },
        })
    end
    table.insert(buttons, {
        {
            text = _("Choose a file…"),
            callback = function()
                UIManager:close(dialog)
                self:chooseFileToSend()
            end,
        },
    })
    table.insert(buttons, {
        {
            text = _("Cancel"),
            callback = function() UIManager:close(dialog) end,
        },
    })
    dialog = ButtonDialog:new{
        title = _("Send / Upload"),
        title_align = "center",
        buttons = buttons,
    }
    UIManager:show(dialog)
end

function Send2Ereader:chooseFileToSend()
    UIManager:show(PathChooser:new{
        title = _("Long-press a file to send it"),
        path = G_reader_settings:readSetting("home_dir") or self.destination,
        select_directory = false,
        select_file = true,
        show_files = true,
        onConfirm = function(path)
            self:sendFile(path)
        end,
    })
end

function Send2Ereader:joinSessionDialog()
    local dialog
    dialog = InputDialog:new{
        title = _("Join Send2Ereader session"),
        input = "",
        input_hint = _("Session code (XXX-XXX)"),
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = _("Join"),
                    is_enter_default = true,
                    callback = function()
                        local joined, err = self.client:joinSession(dialog:getInputText(), "KOReader")
                        if not joined then
                            DiagnosticLog.log("[session] join:failed", tostring(err or "unknown"))
                            self:showMessage(T(_("Could not join session.\n\n%1"), display_error(err)))
                            return
                        end
                        local supplied_code = tostring(dialog:getInputText() or ""):upper():gsub("%-", "")
                        self:setSession({
                            sessionId = joined.sessionId,
                            capability = joined.accessToken,
                            deviceId = joined.deviceId,
                            owner = false,
                            joinCode = joined.joinCode or supplied_code,
                            expiresAt = joined.expiresAt,
                            receiveMode = true,
                        })
                        UIManager:close(dialog)
                        self:openDashboard()
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
end

function Send2Ereader:updateCatalogSeen(items)
    local new_count = 0
    for _, item in ipairs(items or {}) do
        if item.id and not self.catalog_seen_ids[item.id] then
            self.catalog_seen_ids[item.id] = true
            new_count = new_count + 1
        end
    end
    return new_count
end

function Send2Ereader:pollSessionCatalog(show_errors)
    local session = self.session
    if not session then return nil end

    DiagnosticLog.log("[catalog] poll:start", "session=" .. tostring(session.sessionId))
    local catalog, err = self.client:getCatalog(session.sessionId, session.capability)
    if not catalog then
        DiagnosticLog.log("[catalog] poll:failed",
            "session=" .. tostring(session.sessionId) .. " error=" .. tostring(err or "unknown"))
        if show_errors then
            self:showMessage(T(_("Could not load received books.\n\n%1"), display_error(err)))
        end
        return nil
    end

    local items = catalog.items or {}
    self.catalog = catalog
    if catalog.expiresAt then
        session.expiresAt = catalog.expiresAt
    end
    local new_count = self:updateCatalogSeen(items)
    self:cacheCatalogCovers(items)
    DiagnosticLog.log("[catalog] poll:complete",
        "session=" .. tostring(session.sessionId)
        .. " item_count=" .. tostring(catalog.itemCount or #items)
        .. " new_count=" .. tostring(new_count))

    if self.session_browser then
        self.session_browser:update(self.session, catalog)
    elseif new_count > 0 and not show_errors then
        self:showMessage(T(
            _("Detected %1 new file(s). Open Send2Ereader → Receive books to view them."),
            new_count
        ), 4)
    end
    return catalog
end

function Send2Ereader:refreshSessionBrowser(show_errors)
    return self:pollSessionCatalog(show_errors == true)
end

function Send2Ereader:openDownloadedItem(item)
    local path = item and item.id and self.downloaded_ids[item.id] or nil
    if not path or not file_exists(path) then
        if item and item.id then self.downloaded_ids[item.id] = nil end
        if self.session_browser then
            self.session_browser:update(self.session, self.catalog)
        end
        self:showMessage(_("The downloaded file is no longer available on this device."), 3)
        return
    end
    if not self.ui or type(self.ui.openFile) ~= "function" then
        self:showMessage(_("KOReader cannot open this file from the current screen."), 3)
        return
    end
    DiagnosticLog.log("[download] item:open",
        "file=" .. tostring(item.id) .. " path=" .. tostring(path))
    UIManager:nextTick(function()
        self.ui:openFile(path)
    end)
end

function Send2Ereader:downloadCatalogItem(item)
    local session = self.session
    if not session or not item then return end
    if self.downloaded_ids[item.id] then
        self:showMessage(T(_("Already downloaded: %1"), item.title or item.filename or _("Book")), 3)
        return
    end

    local destination, err = self.client:downloadFile(
        item.downloadPath,
        session.capability,
        self.destination,
        item.filename or item.title or "download",
        item.sizeBytes
    )
    if not destination then
        self:showMessage(T(_("Download failed.\n\n%1"), display_error(err)))
        return
    end

    self.downloaded_ids[item.id] = destination
    DiagnosticLog.log("[download] item:complete",
        "file=" .. tostring(item.id) .. " destination=" .. tostring(destination))
    if self.session_browser then
        self.session_browser:update(self.session, self.catalog)
    end
    self:showMessage(T(_("Downloaded %1"), item.title or item.filename or _("Book")), 3)
end

function Send2Ereader:downloadReceived()
    local session = self.session
    if not session then
        self:showMessage(_("Start or join a session first."))
        return
    end

    local catalog = self:pollSessionCatalog(true)
    if not catalog then return end

    local items = catalog.items or {}
    if #items == 0 then
        self:showMessage(_("No books have been uploaded to this session yet."), 3)
        return
    end

    DiagnosticLog.log("[download] batch:start",
        "session=" .. tostring(session.sessionId) .. " item_count=" .. tostring(#items))

    local downloaded = 0
    local skipped = 0
    local failures = {}
    for _, item in ipairs(items) do
        if self.downloaded_ids[item.id] then
            skipped = skipped + 1
        else
            local destination, download_err = self.client:downloadFile(
                item.downloadPath,
                session.capability,
                self.destination,
                item.filename or item.title or "download",
                item.sizeBytes
            )
            if destination then
                self.downloaded_ids[item.id] = destination
                downloaded = downloaded + 1
            else
                table.insert(failures, (item.filename or item.id or "?") .. ": " .. display_error(download_err))
            end
        end
    end

    DiagnosticLog.log("[download] batch:complete",
        "session=" .. tostring(session.sessionId)
        .. " downloaded=" .. tostring(downloaded)
        .. " skipped=" .. tostring(skipped)
        .. " failures=" .. tostring(#failures))

    local lines = {
        T(_("Downloaded %1 new file(s) to:"), downloaded),
        self.destination,
    }
    if skipped > 0 then
        table.insert(lines, "")
        table.insert(lines, T(_("Already downloaded in this session: %1"), skipped))
    end
    if #failures > 0 then
        table.insert(lines, "")
        table.insert(lines, _("Failed:"))
        for _, failure in ipairs(failures) do
            table.insert(lines, failure)
        end
    end
    if self.session_browser then
        self.session_browser:update(self.session, self.catalog)
    end
    self:showMessage(table.concat(lines, "\n"))
end

function Send2Ereader:closeSession()
    if not self.session then return end

    local session = self.session
    self:stopCatalogPolling()
    if not session.owner then
        self:setSession(nil)
        self:openDashboard()
        self:showMessage(_("Left the joined session on this device."), 3)
        return
    end

    DiagnosticLog.log("[session] close:start", "id=" .. tostring(session.sessionId))
    local ok, err = self.client:closeSession(session.sessionId, session.capability)
    if not ok then
        DiagnosticLog.log("[session] close:failed", tostring(err or "unknown"))
        self:showMessage(T(_("Could not close session.\n\n%1"), display_error(err)))
        if session.receiveMode then self:startCatalogPolling() end
        return
    end
    self:setSession(nil)
    self:openDashboard()
    DiagnosticLog.log("[session] close:complete", "id=" .. tostring(session.sessionId))
    self:showMessage(_("Transfer session closed."), 3)
end

function Send2Ereader:chooseDestination(after_callback)
    UIManager:show(PathChooser:new{
        title = _("Long-press a folder to use it for received books"),
        path = self.destination,
        select_directory = true,
        select_file = false,
        show_files = false,
        onConfirm = function(path)
            self.destination = path
            self:saveSetting("destination", path)
            self:showMessage(T(_("Download folder set to:\n%1"), path), 3)
            if after_callback then after_callback() end
        end,
    })
end

function Send2Ereader:setServerUrl(after_callback)
    local dialog
    dialog = InputDialog:new{
        title = _("Send2Ereader server address"),
        input = self.server_url,
        input_hint = DEFAULT_SERVER,
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = _("Save"),
                    is_enter_default = true,
                    callback = function()
                        local normalized, err = Client.normalizeBaseUrl(dialog:getInputText())
                        if not normalized then
                            self:showMessage(display_error(err))
                            return
                        end
                        self.server_url = normalized
                        self.client:setBaseUrl(normalized)
                        self:saveSetting("server_url", normalized)
                        self:setSession(nil)
                        UIManager:close(dialog)
                        if after_callback then
                            after_callback()
                        else
                            self:openDashboard()
                        end
                        self:showMessage(T(_("Server set to:\n%1"), normalized), 3)
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
end

function Send2Ereader:testServer(result_callback)
    DiagnosticLog.log("[ui] test-server:start", self.server_url)
    local payload, err = self.client:probe()
    if not payload then
        DiagnosticLog.log("[ui] test-server:failed", tostring(err or "unknown"))
        local summary = T(_("Server test failed.\n\n%1"), display_error(err))
        if result_callback then
            result_callback(false, nil, err, summary)
        else
            self:showMessage(summary)
        end
        return nil, err
    end
    local extensions = payload.allowedFileExtensions or {}
    DiagnosticLog.log("[ui] test-server:complete",
        "server_version=" .. tostring(payload.serverVersion or "?"))
    local summary = T(
        _("Connected to Send2Ereader.\n\nServer version: %1\nAllowed file types: %2"),
        tostring(payload.serverVersion or "?"),
        #extensions > 0 and table.concat(extensions, ", ") or _("server default")
    )
    if result_callback then
        result_callback(true, payload, nil, summary)
    else
        self:showMessage(summary)
    end
    return payload
end

function Send2Ereader:showDebugLog()
    local content, err = DiagnosticLog.readCurrent(96 * 1024)
    if not content then
        self:showMessage(display_error(err))
        return
    end
    UIManager:show(TextViewer:new{
        title = _("Send2Ereader Debug Log"),
        text = content,
        justified = false,
        add_default_buttons = true,
    })
end

function Send2Ereader:showDebugPaths()
    self:showMessage(
        _("Persistent settings:") .. "\n" .. tostring(self.settings_file)
        .. "\n\n" .. _("Debug logs:") .. "\n" .. tostring(DiagnosticLog.dir() or ""),
        nil
    )
end

function Send2Ereader:clearDebugLogs()
    UIManager:show(ConfirmBox:new{
        text = _("Clear all Send2Ereader debug logs?"),
        ok_text = _("Clear"),
        cancel_text = _("Cancel"),
        ok_callback = function()
            local ok = DiagnosticLog.clear()
            self:showMessage(ok and _("Debug logs cleared.") or _("Could not clear debug logs."), 3)
        end,
    })
end

function Send2Ereader:addToMainMenu(menu_items)
    menu_items.send2ereader = {
        text = _("Send2Ereader"),
        sorting_hint = "tools",
        callback = function()
            self:openDashboard()
        end,
    }
end

function Send2Ereader:onExit()
    self:stopCatalogPolling()
    DiagnosticLog.log("[plugin] exit")
    if self.session and self.session.owner then
        pcall(function()
            self.client:closeSession(self.session.sessionId, self.session.capability)
        end)
    end
end

return Send2Ereader
