local source = debug.getinfo(1, "S").source
local plugin_dir = source:match("@(.+)/spec/[^/]+$") or "."
package.path = plugin_dir .. "/?.lua;" .. plugin_dir .. "/?/init.lua;" .. package.path

local requests = {}

local function file_attributes(path)
    local file = io.open(path, "rb")
    if not file then return nil end
    local size = file:seek("end")
    file:close()
    return { mode = "file", size = size }
end

package.preload["libs/libkoreader-lfs"] = function()
    return { attributes = file_attributes }
end

package.preload["ltn12"] = function()
    return {
        source = {
            string = function(value)
                local sent = false
                return function()
                    if sent then return nil end
                    sent = true
                    return value
                end
            end,
        },
        sink = {
            table = function(target)
                return function(chunk)
                    if chunk then table.insert(target, chunk) end
                    return 1
                end
            end,
            file = function(file)
                return function(chunk)
                    if chunk then file:write(chunk) else file:close() end
                    return 1
                end
            end,
        },
    }
end

package.preload["rapidjson"] = function()
    return {
        encode = function(value)
            if value and value.displayName then
                return '{"displayName":"' .. tostring(value.displayName) .. '"}'
            end
            return "{}"
        end,
        decode = function(raw)
            if raw:find('"service":"send2ereader"', 1, true) then
                return { service = "send2ereader", serverVersion = "0.1.0", allowedFileExtensions = { "epub", "pdf" } }
            elseif raw:find('"ownerToken":"x"', 1, true) then
                return { id = "session-owner", ownerToken = "x", joinCode = "G7K2Q9" }
            elseif raw:find('"accessToken":"y"', 1, true) then
                return { sessionId = "session-owner", deviceId = "device-1", accessToken = "y" }
            elseif raw:find('"kind":"send2ereader-session-catalog"', 1, true) then
                return {
                    kind = "send2ereader-session-catalog",
                    items = {
                        { id = "file1", filename = "received.epub", downloadPath = "/api/v1/files/file1", sizeBytes = 15 },
                    },
                }
            elseif raw:find('"files"', 1, true) then
                return { files = { { id = "uploaded-1", filename = "sample.txt" } } }
            elseif raw:find('"error"', 1, true) then
                return { error = "test_error" }
            end
            error("unexpected JSON in test stub: " .. tostring(raw))
        end,
    }
end

local function consume_source(source_fn)
    local chunks = {}
    if not source_fn then return "" end
    while true do
        local chunk = source_fn()
        if not chunk then break end
        table.insert(chunks, chunk)
    end
    return table.concat(chunks)
end

local function feed_sink(sink, body)
    if not sink then return end
    if body and body ~= "" then sink(body) end
    sink(nil)
end

local function fake_request(request)
    request.captured_body = consume_source(request.source)
    table.insert(requests, request)

    local body, status = "", 200
    if request.url:match("/api/v1$") and request.method == "GET" then
        body = '{"service":"send2ereader","serverVersion":"0.1.0"}'
    elseif request.url:match("/api/v1/sessions$") and request.method == "POST" then
        status, body = 201, '{"id":"session-owner","ownerToken":"x","joinCode":"G7K2Q9"}'
    elseif request.url:match("/api/v1/sessions/G7K2Q9/join$") and request.method == "POST" then
        status, body = 201, '{"sessionId":"session-owner","deviceId":"device-1","accessToken":"y"}'
    elseif request.url:match("/api/v1/sessions/session%-owner/catalog%.json$") then
        body = '{"kind":"send2ereader-session-catalog","items":[{"id":"file1"}]}'
    elseif request.url:match("/api/v1/sessions/session%-owner/files$") and request.method == "POST" then
        status, body = 202, '{"files":[{"id":"uploaded-1"}]}'
    elseif request.url:match("/api/v1/files/file1/cover$") and request.method == "GET" then
        body = "cover-bytes"
    elseif request.url:match("/api/v1/files/file1$") and request.method == "GET" then
        body = "received-bytes!"
    elseif request.url:match("/api/v1/sessions/session%-owner$") and request.method == "DELETE" then
        status = 204
    else
        status, body = 404, '{"error":"test_error"}'
    end

    feed_sink(request.sink, body)
    return 1, status, { ["content-type"] = "application/json" }, "HTTP/1.1 " .. tostring(status)
end

package.preload["socket.http"] = function() return { request = fake_request } end
package.preload["ssl.https"] = function() return { request = fake_request } end

local Client = require("send2ereader/client")

local function assert_equal(actual, expected, label)
    if actual ~= expected then
        error((label or "assert_equal") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
    end
end

local function assert_true(value, label)
    if not value then error(label or "assert_true failed") end
end

assert_equal(assert(Client.normalizeBaseUrl("  https://send.example.test///  ")), "https://send.example.test", "normalize URL")
assert_true(Client.normalizeBaseUrl("ftp://send.example.test") == nil, "reject unsupported URL")
assert_equal(Client.basename("C:\\Books\\Example.epub"), "Example.epub", "Windows basename")
assert_equal(Client.safeFilename("../evil.txt"), "evil.txt", "safe filename")

local log_lines = {}
local client = assert(Client:new("https://send.example.test", function(event, details)
    table.insert(log_lines, tostring(event) .. " " .. tostring(details or ""))
end, "0.1.1.1"))
assert_equal(assert(client:probe()).service, "send2ereader", "probe service")
assert_equal(requests[#requests].headers["User-Agent"], "send2ereader.koplugin/0.1.1.1", "four-part version user agent")
assert_equal(assert(client:createSession()).joinCode, "G7K2Q9", "owner join code")
local redacted = Client.redactForLog('{"ownerToken":"x","accessToken":"y"}')
assert_true(redacted:find('"ownerToken":"x"', 1, true) == nil, "owner token redacted")
assert_true(redacted:find('"accessToken":"y"', 1, true) == nil, "access token redacted")

local before_invalid = #requests
local invalid, invalid_err = client:joinSession("bad")
assert_true(invalid == nil and invalid_err ~= nil, "invalid join code")
assert_equal(#requests, before_invalid, "invalid join should not use HTTP")

assert_equal(assert(client:joinSession("G7K2Q9", "KOReader")).accessToken, "y", "joined capability")
assert_true(requests[#requests].captured_body:find('"displayName":"KOReader"', 1, true) ~= nil, "join JSON body")
assert_equal(assert(client:joinSession("G7K-2Q9", "KOReader")).accessToken, "y", "formatted joined capability")
assert_true(requests[#requests].url:match("/api/v1/sessions/G7K2Q9/join$") ~= nil, "formatted code normalized in URL")
assert_equal(assert(client:getCatalog("session-owner", "y")).items[1].filename, "received.epub", "catalog filename")

local temp_root = "/tmp/send2ereader-client-test-" .. tostring(os.time()) .. "-" .. tostring(math.random(10000, 99999))
assert_equal(os.execute("mkdir -p '" .. temp_root .. "'"), 0, "create temp directory")
local upload_path = temp_root .. "/sample.txt"
local upload_file = assert(io.open(upload_path, "wb"))
upload_file:write("hello-upload")
upload_file:close()

assert_equal(assert(client:uploadFile("session-owner", "x", upload_path)).files[1].id, "uploaded-1", "upload response")
local upload_request = requests[#requests]
assert_true(upload_request.headers["Content-Type"]:find("multipart/form-data", 1, true) ~= nil, "multipart content type")
assert_true(upload_request.captured_body:find('name="files"', 1, true) ~= nil, "multipart field")
assert_true(upload_request.captured_body:find('filename="sample.txt"', 1, true) ~= nil, "multipart filename")
assert_true(upload_request.captured_body:find("hello-upload", 1, true) ~= nil, "multipart bytes")

local existing_path = temp_root .. "/received.epub"
local existing = assert(io.open(existing_path, "wb"))
existing:write("existing")
existing:close()
assert_equal(assert(Client.uniqueDestination(temp_root, "received.epub")), temp_root .. "/received (1).epub", "unique destination")

local downloaded = assert(client:downloadFile("/api/v1/files/file1", "y", temp_root, "fresh.epub", 15))
assert_equal(downloaded, temp_root .. "/fresh.epub", "download path")
local downloaded_file = assert(io.open(downloaded, "rb"))
assert_equal(downloaded_file:read("*a"), "received-bytes!", "download contents")
downloaded_file:close()

local cover_path = temp_root .. "/cover.png"
assert_equal(assert(client:downloadAsset("/api/v1/files/file1/cover", "y", cover_path)), cover_path, "cover cache path")
local cover_file = assert(io.open(cover_path, "rb"))
assert_equal(cover_file:read("*a"), "cover-bytes", "cover cache contents")
cover_file:close()

assert_true(client:closeSession("session-owner", "x"), "close session")
assert_equal(client:joinUrl("G7K2Q9"), "https://send.example.test/#code=G7K2Q9", "join URL")

os.execute("rm -rf '" .. temp_root .. "'")
print("client_test.lua: ok")
