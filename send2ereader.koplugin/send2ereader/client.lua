local Client = {}
Client.__index = Client

local http = require("socket.http")
local https = require("ssl.https")
local lfs = require("libs/libkoreader-lfs")
local ltn12 = require("ltn12")
local rapidjson = require("rapidjson")

local USER_AGENT_PREFIX = "send2ereader.koplugin/"
local CHUNK_SIZE = 64 * 1024
local MAX_LOG_BODY = 2048

local function trim(value)
    return tostring(value or ""):match("^%s*(.-)%s*$")
end

local function request_function(url)
    if url:match("^https://") then
        return https.request
    end
    return http.request
end

local function decode_json(raw)
    if not raw or raw == "" then
        return nil
    end
    local ok, decoded = pcall(rapidjson.decode, raw)
    if ok then
        return decoded
    end
    return nil
end

local function encode_json(value)
    local ok, encoded = pcall(rapidjson.encode, value)
    if not ok then
        return nil, tostring(encoded)
    end
    return encoded
end

local function http_error(status, raw, decoded)
    if type(decoded) == "table" and decoded.error then
        return tostring(decoded.error)
    end
    if raw and raw ~= "" then
        return "HTTP " .. tostring(status) .. ": " .. raw:sub(1, 240)
    end
    return "HTTP " .. tostring(status)
end

local function redact_for_log(value)
    local text = tostring(value or "")
    text = text:gsub('("ownerToken"%s*:%s*")[^"]*(")', '%1<redacted>%2')
    text = text:gsub('("accessToken"%s*:%s*")[^"]*(")', '%1<redacted>%2')
    text = text:gsub('("token"%s*:%s*")[^"]*(")', '%1<redacted>%2')
    text = text:gsub("([Aa]uthorization:%s*[Bb]earer%s+)[^%s]+", "%1<redacted>")
    text = text:gsub("([Bb]earer%s+)[%w%._~%+/%-=]+", "%1<redacted>")
    text = text:gsub("[\r\n]+", " ")
    if #text > MAX_LOG_BODY then
        text = text:sub(1, MAX_LOG_BODY) .. "...<truncated>"
    end
    return text
end

local function header_value(headers, name)
    if type(headers) ~= "table" then return nil end
    return headers[name] or headers[name:lower()]
end

function Client.redactForLog(value)
    return redact_for_log(value)
end

function Client.normalizeBaseUrl(value)
    local normalized = trim(value):gsub("/+$", "")
    if not normalized:match("^https?://[^/]+") then
        return nil, "Server URL must start with http:// or https://"
    end
    return normalized
end

function Client.basename(path)
    local name = tostring(path or ""):gsub("\\", "/"):match("([^/]+)$")
    return name or "book"
end

function Client.safeFilename(name)
    local cleaned = Client.basename(name)
        :gsub("%c", "_")
        :gsub("[/\\]", "_")
        :gsub("^%s+", "")
        :gsub("%s+$", "")
    if cleaned == "" or cleaned == "." or cleaned == ".." then
        return "download"
    end
    return cleaned
end

local function join_path(dir, name)
    if dir == "/" then
        return "/" .. name
    end
    return tostring(dir):gsub("/+$", "") .. "/" .. name
end

function Client.uniqueDestination(dir, filename)
    local safe = Client.safeFilename(filename)
    local candidate = join_path(dir, safe)
    if not lfs.attributes(candidate) then
        return candidate
    end

    local stem, extension = safe:match("^(.*)(%.[^.]*)$")
    if not stem then
        stem, extension = safe, ""
    end
    for index = 1, 9999 do
        candidate = join_path(dir, string.format("%s (%d)%s", stem, index, extension))
        if not lfs.attributes(candidate) then
            return candidate
        end
    end
    return nil, "Unable to choose a unique destination filename"
end

function Client:new(server_url, logger, plugin_version)
    local normalized, err = self.normalizeBaseUrl(server_url)
    if not normalized then
        return nil, err
    end
    return setmetatable({
        base_url = normalized,
        logger = logger,
        user_agent = USER_AGENT_PREFIX .. tostring(plugin_version or "unknown"),
        request_sequence = 0,
    }, self)
end

function Client:setLogger(logger)
    self.logger = logger
end

function Client:_log(event, details)
    if type(self.logger) ~= "function" then return end
    pcall(self.logger, event, redact_for_log(details))
end

function Client:_nextRequestId()
    self.request_sequence = (self.request_sequence or 0) + 1
    return tostring(self.request_sequence)
end

function Client:setBaseUrl(server_url)
    local normalized, err = self.normalizeBaseUrl(server_url)
    if not normalized then
        return nil, err
    end
    self.base_url = normalized
    self:_log("[client] server-url", normalized)
    return true
end

function Client:_url(path)
    if tostring(path):match("^https?://") then
        return path
    end
    if tostring(path):sub(1, 1) ~= "/" then
        path = "/" .. tostring(path)
    end
    return self.base_url .. path
end

function Client:_request(method, path, token, body)
    local request_id = self:_nextRequestId()
    local url = self:_url(path)
    local chunks = {}
    local headers = {
        ["User-Agent"] = self.user_agent,
        ["Accept"] = "application/json",
        ["Connection"] = "close",
    }

    local source
    local encoded
    if body ~= nil then
        local encode_err
        encoded, encode_err = encode_json(body)
        if not encoded then
            self:_log("[network] request:error",
                "id=" .. request_id .. " method=" .. tostring(method) .. " url=" .. url
                .. " stage=json-encode error=" .. tostring(encode_err))
            return nil, "JSON encode failed: " .. tostring(encode_err)
        end
        headers["Content-Type"] = "application/json"
        headers["Content-Length"] = tostring(#encoded)
        source = ltn12.source.string(encoded)
    end
    if token then
        headers["Authorization"] = "Bearer " .. token
    end

    local request_details = "id=" .. request_id
        .. " method=" .. tostring(method)
        .. " url=" .. url
        .. " auth=" .. (token and "present" or "none")
    if encoded then
        request_details = request_details .. " body=" .. encoded
    end
    self:_log("[network] request:start", request_details)

    local ok, status, response_headers, status_line = request_function(url)({
        url = url,
        method = method,
        headers = headers,
        source = source,
        sink = ltn12.sink.table(chunks),
        redirect = false,
    })
    if not ok then
        local network_error = tostring(status or status_line or "network error")
        self:_log("[network] request:failed",
            "id=" .. request_id .. " method=" .. tostring(method) .. " url=" .. url
            .. " error=" .. network_error)
        return nil, network_error
    end

    status = tonumber(status) or 0
    local raw = table.concat(chunks)
    local decoded = decode_json(raw)
    self:_log("[network] response",
        "id=" .. request_id
        .. " method=" .. tostring(method)
        .. " url=" .. url
        .. " status=" .. tostring(status)
        .. " content_type=" .. tostring(header_value(response_headers, "content-type") or "")
        .. " content_length=" .. tostring(header_value(response_headers, "content-length") or #raw)
        .. " body=" .. raw)

    if status < 200 or status >= 300 then
        return nil, http_error(status, raw, decoded), status, decoded or raw, response_headers
    end
    return decoded, nil, status, response_headers
end

function Client:probe()
    local payload, err, status = self:_request("GET", "/api/v1")
    if not payload then
        return nil, err or ("HTTP " .. tostring(status))
    end
    if payload.service ~= "send2ereader" then
        return nil, "Server is not a Send2Ereader API"
    end
    return payload
end

function Client:createSession()
    local payload, err, status = self:_request("POST", "/api/v1/sessions")
    if not payload or status ~= 201 then
        return nil, err or "Unable to create session"
    end
    return payload
end

function Client:joinSession(code, display_name)
    local supplied = trim(code):upper()
    local normalized = supplied
    if supplied:match("^[A-Z0-9][A-Z0-9][A-Z0-9]%-[A-Z0-9][A-Z0-9][A-Z0-9]$") then
        normalized = supplied:gsub("%-", "")
    end
    if #normalized ~= 6 or not normalized:match("^[A-Z0-9]+$") then
        self:_log("[session] join:rejected", "reason=invalid-code-format")
        return nil, "Join code must be 6 letters or numbers"
    end
    local payload, err, status = self:_request(
        "POST",
        "/api/v1/sessions/" .. normalized .. "/join",
        nil,
        { displayName = display_name or "KOReader" }
    )
    if not payload or status ~= 201 then
        return nil, err or "Unable to join session"
    end
    return payload
end

function Client:getCatalog(session_id, token)
    local payload, err = self:_request(
        "GET",
        "/api/v1/sessions/" .. tostring(session_id) .. "/catalog.json",
        token
    )
    if not payload then
        return nil, err or "Unable to load session catalog"
    end
    return payload
end

function Client:closeSession(session_id, owner_token)
    local _, err, status = self:_request(
        "DELETE",
        "/api/v1/sessions/" .. tostring(session_id),
        owner_token
    )
    if err or status ~= 204 then
        return nil, err or "Unable to close session"
    end
    return true
end

local function multipart_source(prefix, file, suffix)
    local phase = "prefix"
    return function()
        if phase == "prefix" then
            phase = "file"
            return prefix
        end
        if phase == "file" then
            local chunk = file:read(CHUNK_SIZE)
            if chunk then
                return chunk
            end
            file:close()
            phase = "suffix"
        end
        if phase == "suffix" then
            phase = "done"
            return suffix
        end
        return nil
    end
end

function Client:uploadFile(session_id, token, file_path)
    local attributes = lfs.attributes(file_path)
    if not attributes or attributes.mode ~= "file" then
        self:_log("[upload] rejected", "path=" .. tostring(file_path) .. " reason=file-missing")
        return nil, "File does not exist: " .. tostring(file_path)
    end

    local file, open_err = io.open(file_path, "rb")
    if not file then
        self:_log("[upload] rejected", "path=" .. tostring(file_path) .. " reason=open-failed error=" .. tostring(open_err))
        return nil, "Cannot open file: " .. tostring(open_err)
    end

    local request_id = self:_nextRequestId()
    local boundary = "----send2ereader-" .. tostring(os.time()) .. "-" .. tostring(math.random(100000, 999999))
    local filename = Client.safeFilename(Client.basename(file_path))
    local quoted_filename = filename:gsub("\\", "_"):gsub('"', "_")
    local prefix = "--" .. boundary .. "\r\n"
        .. 'Content-Disposition: form-data; name="files"; filename="' .. quoted_filename .. '"\r\n'
        .. "Content-Type: application/octet-stream\r\n\r\n"
    local suffix = "\r\n--" .. boundary .. "--\r\n"
    local url = self:_url("/api/v1/sessions/" .. tostring(session_id) .. "/files")
    local chunks = {}

    self:_log("[upload] request:start",
        "id=" .. request_id
        .. " session=" .. tostring(session_id)
        .. " url=" .. url
        .. " filename=" .. filename
        .. " bytes=" .. tostring(attributes.size)
        .. " auth=" .. (token and "present" or "none"))

    local ok, status, response_headers, status_line = request_function(url)({
        url = url,
        method = "POST",
        headers = {
            ["User-Agent"] = self.user_agent,
            ["Accept"] = "application/json",
            ["Authorization"] = "Bearer " .. token,
            ["Content-Type"] = "multipart/form-data; boundary=" .. boundary,
            ["Content-Length"] = tostring(#prefix + attributes.size + #suffix),
            ["Connection"] = "close",
        },
        source = multipart_source(prefix, file, suffix),
        sink = ltn12.sink.table(chunks),
        redirect = false,
    })
    if not ok then
        pcall(function() file:close() end)
        local network_error = tostring(status or status_line or "network error")
        self:_log("[upload] request:failed",
            "id=" .. request_id .. " session=" .. tostring(session_id)
            .. " filename=" .. filename .. " error=" .. network_error)
        return nil, network_error
    end

    status = tonumber(status) or 0
    local raw = table.concat(chunks)
    local decoded = decode_json(raw)
    self:_log("[upload] response",
        "id=" .. request_id
        .. " session=" .. tostring(session_id)
        .. " filename=" .. filename
        .. " status=" .. tostring(status)
        .. " content_type=" .. tostring(header_value(response_headers, "content-type") or "")
        .. " body=" .. raw)

    if status ~= 202 then
        return nil, http_error(status, raw, decoded), status, decoded or raw, response_headers
    end
    return decoded or { files = {} }
end

function Client:downloadFile(download_path, token, destination_dir, filename, expected_size)
    local destination, destination_err = Client.uniqueDestination(destination_dir, filename)
    if not destination then
        self:_log("[download] rejected", "filename=" .. tostring(filename) .. " error=" .. tostring(destination_err))
        return nil, destination_err
    end
    local temp_path = destination .. ".part"
    local file, open_err = io.open(temp_path, "wb")
    if not file then
        self:_log("[download] rejected", "destination=" .. destination .. " error=" .. tostring(open_err))
        return nil, "Cannot create download: " .. tostring(open_err)
    end

    local request_id = self:_nextRequestId()
    local url = self:_url(download_path)
    self:_log("[download] request:start",
        "id=" .. request_id
        .. " url=" .. url
        .. " destination=" .. destination
        .. " expected_bytes=" .. tostring(expected_size or "")
        .. " auth=" .. (token and "present" or "none"))

    local ok, status, response_headers, status_line = request_function(url)({
        url = url,
        method = "GET",
        headers = {
            ["User-Agent"] = self.user_agent,
            ["Authorization"] = "Bearer " .. token,
            ["Accept"] = "*/*",
            ["Connection"] = "close",
        },
        sink = ltn12.sink.file(file),
        redirect = false,
    })
    if not ok then
        pcall(function() file:close() end)
        os.remove(temp_path)
        local network_error = tostring(status or status_line or "network error")
        self:_log("[download] request:failed",
            "id=" .. request_id .. " url=" .. url .. " error=" .. network_error)
        return nil, network_error
    end

    status = tonumber(status) or 0
    local attributes = lfs.attributes(temp_path)
    local actual_size = attributes and tonumber(attributes.size) or 0
    self:_log("[download] response",
        "id=" .. request_id
        .. " url=" .. url
        .. " status=" .. tostring(status)
        .. " content_type=" .. tostring(header_value(response_headers, "content-type") or "")
        .. " content_length=" .. tostring(header_value(response_headers, "content-length") or "")
        .. " received_bytes=" .. tostring(actual_size))

    if status ~= 200 then
        os.remove(temp_path)
        return nil, "HTTP " .. tostring(status)
    end

    if expected_size and attributes and tonumber(expected_size) ~= tonumber(attributes.size) then
        os.remove(temp_path)
        self:_log("[download] validation:failed",
            "id=" .. request_id
            .. " expected_bytes=" .. tostring(expected_size)
            .. " actual_bytes=" .. tostring(attributes.size))
        return nil, "Downloaded file size did not match the server catalog"
    end

    local renamed, rename_err = os.rename(temp_path, destination)
    if not renamed then
        os.remove(temp_path)
        self:_log("[download] finalize:failed", "id=" .. request_id .. " error=" .. tostring(rename_err))
        return nil, "Cannot finish download: " .. tostring(rename_err)
    end

    self:_log("[download] complete",
        "id=" .. request_id .. " destination=" .. destination .. " bytes=" .. tostring(actual_size))
    return destination
end

function Client:downloadAsset(download_path, token, destination)
    if not download_path or download_path == "" or not destination or destination == "" then
        return nil, "Asset path and destination are required"
    end

    local temp_path = destination .. ".part"
    local file, open_err = io.open(temp_path, "wb")
    if not file then
        self:_log("[asset] rejected", "destination=" .. tostring(destination) .. " error=" .. tostring(open_err))
        return nil, "Cannot create cached asset: " .. tostring(open_err)
    end

    local request_id = self:_nextRequestId()
    local url = self:_url(download_path)
    self:_log("[asset] request:start",
        "id=" .. request_id
        .. " url=" .. url
        .. " destination=" .. destination
        .. " auth=" .. (token and "present" or "none"))

    local ok, status, response_headers, status_line = request_function(url)({
        url = url,
        method = "GET",
        headers = {
            ["User-Agent"] = self.user_agent,
            ["Authorization"] = "Bearer " .. token,
            ["Accept"] = "image/*",
            ["Connection"] = "close",
        },
        sink = ltn12.sink.file(file),
        redirect = false,
    })
    if not ok then
        pcall(function() file:close() end)
        os.remove(temp_path)
        local network_error = tostring(status or status_line or "network error")
        self:_log("[asset] request:failed", "id=" .. request_id .. " url=" .. url .. " error=" .. network_error)
        return nil, network_error
    end

    status = tonumber(status) or 0
    local attributes = lfs.attributes(temp_path)
    self:_log("[asset] response",
        "id=" .. request_id
        .. " url=" .. url
        .. " status=" .. tostring(status)
        .. " content_type=" .. tostring(header_value(response_headers, "content-type") or "")
        .. " received_bytes=" .. tostring(attributes and attributes.size or 0))
    if status ~= 200 or not attributes or tonumber(attributes.size or 0) <= 0 then
        os.remove(temp_path)
        return nil, status ~= 200 and ("HTTP " .. tostring(status)) or "Empty asset response"
    end

    os.remove(destination)
    local renamed, rename_err = os.rename(temp_path, destination)
    if not renamed then
        os.remove(temp_path)
        return nil, "Cannot finish cached asset: " .. tostring(rename_err)
    end
    return destination
end

function Client:joinUrl(join_code)
    return self.base_url .. "/#code=" .. tostring(join_code or "")
end

return Client
