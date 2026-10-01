local ConfirmBox = require("ui/widget/confirmbox")
local Device = require("device")
local InfoMessage = require("ui/widget/infomessage")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local lfs = require("libs/libkoreader-lfs")
local ltn12 = require("ltn12")
local rapidjson = require("rapidjson")
local https = require("ssl.https")
local _ = require("gettext")

local Updater = {}

local REPO = "jadehawk/send2ereader.koplugin"
local LATEST_URL = "https://api.github.com/repos/" .. REPO .. "/releases/latest"
local ASSET_NAME = "send2ereader.koplugin.zip"
local PLUGIN_DIR_NAME = "send2ereader.koplugin"
local RELEASE_DOWNLOAD_PREFIX = "https://github.com/" .. REPO .. "/releases/download/"

local function parseVersion(value)
    if type(value) ~= "string" then return nil end

    local a, b, c, d = value:match("^v?(%d+)%.(%d+)%.(%d+)%.(%d+)$")
    if a then
        return tonumber(a), tonumber(b), tonumber(c), tonumber(d)
    end

    a, b, c = value:match("^v?(%d+)%.(%d+)%.(%d+)$")
    if not a then return nil end
    return tonumber(a), tonumber(b), tonumber(c), 0
end

function Updater.isNewer(candidate, current)
    local aa, ab, ac, ad = parseVersion(candidate)
    local ca, cb, cc, cd = parseVersion(current)
    if aa == nil or ca == nil then return false end
    if aa ~= ca then return aa > ca end
    if ab ~= cb then return ab > cb end
    if ac ~= cc then return ac > cc end
    return ad > cd
end

local function trustedReleaseUrl(value)
    return type(value) == "string"
        and value:sub(1, #RELEASE_DOWNLOAD_PREFIX) == RELEASE_DOWNLOAD_PREFIX
        and not value:find("[%c%s]")
end

local function safeArchivePath(value)
    if type(value) ~= "string" or value == "" or value:find("\0", 1, true) then return nil end
    local normalized = value:gsub("\\", "/")
    if normalized:sub(1, 1) == "/" or normalized:match("^%a:/") then return nil end

    local parts = {}
    for part in normalized:gmatch("[^/]+") do
        if part == ".." then return nil end
        if part ~= "." and part ~= "" then parts[#parts + 1] = part end
    end
    if #parts == 0 then return nil end
    return table.concat(parts, "/")
end

Updater._parseVersion = parseVersion
Updater._trustedReleaseUrl = trustedReleaseUrl
Updater._safeArchivePath = safeArchivePath

local function request(url, sink)
    local ok, code, headers, status = https.request{
        url = url,
        method = "GET",
        headers = {
            ["Accept"] = "application/vnd.github+json",
            ["Accept-Encoding"] = "identity",
            ["User-Agent"] = "Send2Ereader-KOReader",
            ["X-GitHub-Api-Version"] = "2022-11-28",
        },
        sink = sink,
    }
    if not ok then return nil, tostring(code or status or "HTTPS request failed") end
    if tonumber(code) ~= 200 then return nil, "GitHub returned HTTP " .. tostring(code) end
    return true, headers
end

local function releaseFromTable(release)
    if type(release) ~= "table" then return nil, "Could not read GitHub release information" end

    local tag = release.tag_name
    if not parseVersion(tag) then return nil, "Latest GitHub release has an invalid version tag" end

    for _, asset in ipairs(release.assets or {}) do
        if asset.name == ASSET_NAME and type(asset.browser_download_url) == "string" then
            if not trustedReleaseUrl(asset.browser_download_url) then
                return nil, "Latest release contains an unexpected download URL"
            end
            return {
                version = tag:gsub("^v", ""),
                url = asset.browser_download_url,
            }
        end
    end
    return nil, "Latest release does not contain " .. ASSET_NAME
end

Updater._releaseFromTable = releaseFromTable

local function latestRelease()
    local chunks = {}
    local ok, err = request(LATEST_URL, ltn12.sink.table(chunks))
    if not ok then return nil, err end

    local decoded_ok, release = pcall(rapidjson.decode, table.concat(chunks))
    if not decoded_ok then return nil, "Could not read GitHub release information" end
    return releaseFromTable(release)
end

Updater._latestRelease = latestRelease

local function sq(path)
    return "'" .. tostring(path):gsub("'", "'\\''") .. "'"
end

local function childNames(dir)
    local names = {}
    local ok, iterator, dir_obj = pcall(lfs.dir, dir)
    if not ok or not iterator then return names end
    for name in iterator, dir_obj do
        if name ~= "." and name ~= ".." then names[#names + 1] = name end
    end
    return names
end

local function prepareExtractedPlugin(raw_dir, staging)
    local packaged = raw_dir .. "/" .. PLUGIN_DIR_NAME
    if lfs.attributes(packaged .. "/main.lua", "mode") == "file"
        and lfs.attributes(packaged .. "/_meta.lua", "mode") == "file" then
        if not os.rename(packaged, staging) then return nil, "Could not prepare extracted update" end
        os.execute("rm -rf " .. sq(raw_dir))
        return true
    end

    if lfs.attributes(raw_dir .. "/main.lua", "mode") == "file"
        and lfs.attributes(raw_dir .. "/_meta.lua", "mode") == "file" then
        if not os.rename(raw_dir, staging) then return nil, "Could not prepare extracted update" end
        return true
    end

    local names = childNames(raw_dir)
    local root = names[1]
    if #names == 1 and root
        and lfs.attributes(raw_dir .. "/" .. root, "mode") == "directory"
        and lfs.attributes(raw_dir .. "/" .. root .. "/main.lua", "mode") == "file"
        and lfs.attributes(raw_dir .. "/" .. root .. "/_meta.lua", "mode") == "file" then
        if not os.rename(raw_dir .. "/" .. root, staging) then return nil, "Could not prepare extracted update" end
        os.execute("rm -rf " .. sq(raw_dir))
        return true
    end

    return nil, "Update archive does not contain a valid Send2Ereader plugin"
end

local function unpack(zip_path, staging, raw_dir)
    os.execute("rm -rf " .. sq(raw_dir))
    if not lfs.mkdir(raw_dir) and lfs.attributes(raw_dir, "mode") ~= "directory" then
        return nil, "Could not create update staging directory"
    end

    local has_archiver, Archiver = pcall(require, "ffi/archiver")
    if has_archiver and type(Archiver) == "table" and Archiver.Reader then
        local arc = Archiver.Reader:new()
        if not arc:open(zip_path) then
            local err = arc.err
            arc:close()
            return nil, tostring(err or "Could not open update archive")
        end

        for entry in arc:iterate() do
            if entry.mode ~= "file" and entry.mode ~= "directory" then
                arc:close()
                os.execute("rm -rf " .. sq(raw_dir))
                return nil, "Update archive contains an unsupported entry type"
            end
            local normalized = safeArchivePath(entry.path)
            if not normalized then
                arc:close()
                os.execute("rm -rf " .. sq(raw_dir))
                return nil, "Update archive contains an unsafe path"
            end
            if not arc:extractToPath(entry.path, raw_dir .. "/" .. normalized) then break end
        end

        local err = arc.err
        arc:close()
        if err then return nil, tostring(err) end
        return prepareExtractedPlugin(raw_dir, staging)
    end

    if type(Device.unpackArchive) ~= "function" then
        return nil, "This KOReader build cannot extract update archives"
    end

    local ok, err = Device:unpackArchive(zip_path, raw_dir, true)
    if not ok then return nil, tostring(err or "Archive extraction failed") end
    return prepareExtractedPlugin(raw_dir, staging)
end

local function packagedVersion(dir)
    local file = io.open(dir .. "/_meta.lua", "rb")
    if not file then return nil end
    local content = file:read("*a")
    file:close()
    local version = content and content:match('version%s*=%s*"([^"]+)"') or nil
    if not parseVersion(version) then return nil end
    return version
end

local function apply(plugin_dir, release)
    local dir = tostring(plugin_dir or ""):gsub("/+$", "")
    local parent = dir:match("^(.*)/[^/]+$")
    local name = dir:match("([^/]+)$")
    if not parent or not name then return nil, "Cannot determine plugin directory" end

    local zip_path = parent .. "/send2ereader-update.zip"
    local staging = parent .. "/" .. name .. ".update"
    local raw_dir = parent .. "/" .. name .. ".unpack"
    local backup = parent .. "/" .. name .. ".bak"
    os.execute("rm -rf " .. sq(staging) .. " " .. sq(raw_dir) .. " " .. sq(backup))

    local file, err = io.open(zip_path, "wb")
    if not file then return nil, tostring(err or "Could not create update file") end
    local ok, download_err = request(release.url, ltn12.sink.file(file))
    if not ok then
        os.remove(zip_path)
        return nil, download_err
    end

    local unpack_ok, unpack_err = unpack(zip_path, staging, raw_dir)
    os.remove(zip_path)
    if not unpack_ok then
        os.execute("rm -rf " .. sq(staging) .. " " .. sq(raw_dir))
        return nil, unpack_err
    end

    if lfs.attributes(staging .. "/main.lua", "mode") ~= "file"
        or lfs.attributes(staging .. "/_meta.lua", "mode") ~= "file" then
        os.execute("rm -rf " .. sq(staging))
        return nil, "Update archive does not contain a valid Send2Ereader plugin"
    end

    local staged_version = packagedVersion(staging)
    if staged_version ~= release.version then
        os.execute("rm -rf " .. sq(staging))
        return nil, "Update archive version does not match the GitHub release"
    end

    if not os.rename(dir, backup) then
        os.execute("rm -rf " .. sq(staging))
        return nil, "Could not create plugin backup"
    end
    if not os.rename(staging, dir) then
        os.rename(backup, dir)
        os.execute("rm -rf " .. sq(staging))
        return nil, "Could not install updated plugin"
    end

    os.execute("rm -rf " .. sq(backup) .. " " .. sq(raw_dir))
    return true
end

local function runOnline(callback)
    return NetworkMgr:runWhenOnline(function()
        local ok, result = pcall(callback)
        if not ok then error(result, 0) end
        return result
    end)
end

local function getSkippedVersion(plugin)
    if not plugin.settings_store then return nil end
    return plugin.settings_store:readSetting("skipped_update_version")
end

local function setSkippedVersion(plugin, version)
    if not plugin.settings_store then return nil, "Plugin settings are unavailable" end
    plugin.settings_store:saveSetting("skipped_update_version", version)
    plugin.settings_store:flush()
    return true
end

local function installRelease(plugin, release)
    runOnline(function()
        local updating = InfoMessage:new{
            text = _("Downloading and installing Send2Ereader update..."),
        }
        UIManager:show(updating)
        UIManager:forceRePaint()

        local ok, err = apply(plugin.path, release)
        UIManager:close(updating)
        UIManager:forceRePaint()
        if not ok then
            UIManager:show(InfoMessage:new{
                text = _("Update failed:") .. string.char(10, 10) .. tostring(err),
                timeout = 6,
            })
            return
        end

        setSkippedVersion(plugin, nil)
        UIManager:show(ConfirmBox:new{
            text = _("Send2Ereader v") .. release.version
                .. _(" installed. KOReader must restart to use the update."),
            ok_text = _("Restart now"),
            ok_callback = function()
                UIManager:quit(UIManager.RETURN_CODE_REBOOT or 85)
            end,
            cancel_text = _("Later"),
        })
    end)
end

Updater._installRelease = installRelease

local function promptRelease(plugin, release, automatic)
    local box = {
        text = _("Send2Ereader v") .. release.version .. _(" is available.")
            .. string.char(10, 10)
            .. _("Installed: v") .. plugin.PLUGIN_VERSION
            .. string.char(10, 10)
            .. _("Download and install the update?"),
        ok_text = automatic and _("Yes") or _("Update"),
        ok_callback = function() Updater._installRelease(plugin, release) end,
    }

    if automatic then
        box.cancel_text = _("Skip")
        box.cancel_callback = function()
            local ok, err = setSkippedVersion(plugin, release.version)
            if not ok then
                UIManager:show(InfoMessage:new{
                    text = _("Could not save skipped update version:")
                        .. string.char(10, 10) .. tostring(err),
                    timeout = 6,
                })
                return
            end
            UIManager:show(InfoMessage:new{
                text = _("Send2Ereader v") .. release.version
                    .. _(" will be skipped. You can still install it from Settings > About > Check for Updates."),
                timeout = 7,
            })
        end
    end

    UIManager:show(ConfirmBox:new(box))
end

Updater._promptRelease = promptRelease

function Updater.checkAutomatic(plugin)
    if not NetworkMgr:isOnline() then return end
    runOnline(function()
        local release = Updater._latestRelease()
        if not release then return end
        if not Updater.isNewer(release.version, plugin.PLUGIN_VERSION) then return end
        if release.version == getSkippedVersion(plugin) then return end
        promptRelease(plugin, release, true)
    end)
end

function Updater.check(plugin)
    runOnline(function()
        local checking = InfoMessage:new{ text = _("Checking for Send2Ereader updates...") }
        UIManager:show(checking)
        UIManager:forceRePaint()

        local release, err = Updater._latestRelease()
        UIManager:close(checking)
        UIManager:forceRePaint()
        if not release then
            UIManager:show(InfoMessage:new{
                text = _("Could not check for updates:")
                    .. string.char(10, 10) .. tostring(err),
                timeout = 6,
            })
            return
        end

        if not Updater.isNewer(release.version, plugin.PLUGIN_VERSION) then
            UIManager:show(InfoMessage:new{
                text = _("Send2Ereader is up to date (v") .. plugin.PLUGIN_VERSION .. ").",
                timeout = 4,
            })
            return
        end

        promptRelease(plugin, release, false)
    end)
end

return Updater
