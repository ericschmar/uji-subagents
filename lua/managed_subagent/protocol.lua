local M = { version = 1, max_bytes = 1024 * 1024, max_steering = 32 * 1024 }

function M.terminal(status)
    return status == "completed" or status == "failed" or status == "cancelled"
end

function M.decode(line)
    if type(line) ~= "string" or #line > M.max_bytes then return nil, "event exceeds size limit" end
    local ok, value = pcall(uji.json.decode, line)
    if not ok or type(value) ~= "table" or value.version ~= M.version
        or type(value.type) ~= "string" or type(value.seq) ~= "number" or value.seq < 1 then
        return nil, "invalid worker event"
    end
    return value
end

function M.command(value)
    if type(value) ~= "table" or type(value.id) ~= "string" or #value.id > 128 then
        return nil, "invalid command id"
    end
    if value.action == "stop" then return value end
    if value.action ~= "steer" or type(value.text) ~= "string" or not value.text:find("%S")
        or #value.text > M.max_steering then
        return nil, "steering must contain 1–32768 bytes of nonblank text"
    end
    return value
end

function M.request(port, token, command)
    local response, err = uji.net.request({
        url = "http://127.0.0.1:" .. port .. "/control",
        method = "POST",
        headers = { ["Authorization"] = "Bearer " .. token, ["Content-Type"] = "application/json" },
        body = uji.json.encode(command),
        timeout = 5,
    })
    if not response then return nil, err end
    if response.status ~= 200 then return nil, "worker rejected control request (" .. response.status .. ")" end
    local ok, value = pcall(uji.json.decode, response.body)
    if not ok or type(value) ~= "table" then return nil, "invalid control response" end
    if value.error then return nil, value.error end
    return value
end

function M.serve(conn, token, handle)
    local function reply(code, body)
        local text = uji.json.encode(body)
        conn:write("HTTP/1.1 " ..
        code ..
        "\r\nContent-Type: application/json\r\nConnection: close\r\nContent-Length: " .. #text .. "\r\n\r\n" .. text)
    end
    if (conn:line(3) or ""):gsub("\r$", "") ~= "POST /control HTTP/1.1" then
        return reply("400 Bad Request", { error = "invalid request" })
    end
    local headers, bytes = {}, 0
    while true do
        local line = conn:line(3)
        if type(line) ~= "string" then return end
        line = line:gsub("\r$", "")
        bytes = bytes + #line
        if bytes > 8192 then return reply("431 Request Header Fields Too Large", { error = "headers too large" }) end
        if line == "" then break end
        local key, value = line:match("^([^:]+):%s*(.-)%s*$")
        if not key then return reply("400 Bad Request", { error = "invalid header" }) end
        headers[key:lower()] = value
    end
    if headers.authorization ~= "Bearer " .. token then
        return reply("403 Forbidden", { error = "unauthorized" })
    end
    local length = tonumber(headers["content-length"])
    if not length or length < 1 or length > M.max_steering * 6 + 1024 or length % 1 ~= 0 then
        return reply("413 Content Too Large", { error = "invalid content length" })
    end
    local ok, value = pcall(uji.json.decode, conn:read(length))
    local command, err
    if ok then command, err = M.command(value) end
    if not command then return reply("400 Bad Request", { error = err or "invalid JSON" }) end
    local result, after = handle(command)
    reply("200 OK", result)
    if after then after() end
end

return M
