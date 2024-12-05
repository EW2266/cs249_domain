local cjson = require "cjson"
local websocket = require "resty.websocket.client"

local M = {}

-- Server configuration as an inline Lua table
M.servers = {
    frontend = {
        { ip = "18.119.41.161:3000", weight = 3 },
    },
    backend = {
        { ip = "3.130.25.213:8000", weight = 2 },
    },
    websocket = {
        { ip = "3.130.25.213:4000", weight = 3 },
    },
}

-- Validate server configurations
local function validate_config(config)
    for group, servers in pairs(config) do
        for _, server in ipairs(servers) do
            if not server.ip or not server.weight then
                ngx.log(ngx.ERR, "Invalid server configuration in group ", group)
                return false
            end
        end
    end
    return true
end

if not validate_config(M.servers) then
    ngx.log(ngx.ERR, "Invalid server configuration. Aborting.")
    return
end

-- Perform HTTP health checks
function M.check_http_health(server_list, path)
    local max_retries = 3
    local retry_delay = 500  -- milliseconds

    for _, server in ipairs(server_list) do
        local success = false
        local httpc = require "resty.http"

        for attempt = 1, max_retries do
            local http = httpc.new()
            local res, err = http:request_uri("http://" .. server.ip .. (path or "/api/checkhealth"), {
                method = "POST",
                timeout = 2000,
            })

            if res and res.status == 200 then
                success = true
                break
            else
                ngx.log(ngx.WARN, "HTTP health check failed for ", server.ip, " (Attempt ", attempt, "): ", err)
                if attempt < max_retries then
                    ngx.sleep(retry_delay / 1000)
                end
            end
        end

        if success then
            ngx.log(ngx.DEBUG, "HTTP server is healthy: ", server.ip)
            ngx.shared.health:set(server.ip, true)
        else
            ngx.log(ngx.ERR, "HTTP health check failed for ", server.ip)
            ngx.shared.health:set(server.ip, false)
        end
    end
end

-- Perform WebSocket health checks
function M.check_ws_health(server_list)
    local max_retries = 3
    local retry_delay = 500  -- milliseconds

    for _, server in ipairs(server_list) do
        local success = false
        local host, port = server.ip:match("([^:]+):([^:]+)")

        for attempt = 1, max_retries do
            local wb, err = websocket:new()
            if not wb then
                ngx.log(ngx.ERR, "WebSocket client creation failed for ", server.ip, ": ", err)
                break
            end

            local ok, conn_err = wb:connect("ws://" .. host .. ":" .. port)
            if ok then
                local bytes, ping_err = wb:send_ping()
                if not bytes then
                    ngx.log(ngx.WARN, "WebSocket ping failed for ", server.ip, ": ", ping_err)
                else
                    success = true
                end
                wb:close()
                break
            else
                ngx.log(ngx.WARN, "WebSocket connection failed for ", server.ip, ": ", conn_err)
                if attempt < max_retries then
                    ngx.sleep(retry_delay / 1000)
                end
            end
        end

        if success then
            ngx.log(ngx.DEBUG, "WebSocket server is healthy: ", server.ip)
            ngx.shared.health:set(server.ip, true)
        else
            ngx.log(ngx.ERR, "WebSocket health check failed for ", server.ip)
            ngx.shared.health:set(server.ip, false)
        end
    end
end

-- Weighted IP hash for load balancing
function M.weighted_ip_hash(servers)
    local health = ngx.shared.health
    local total_weight = 0
    local weight_map = {}

    ngx.log(ngx.DEBUG, "Building weighted IP hash for servers")
    for _, server in ipairs(servers) do
        local is_healthy = health:get(server.ip)
        if is_healthy then
            total_weight = total_weight + server.weight
            table.insert(weight_map, { ip = server.ip, cumulative_weight = total_weight })
            ngx.log(ngx.DEBUG, "Added server to weight_map: ", server.ip)
        else
            ngx.log(ngx.WARN, "Skipping unhealthy server: ", server.ip)
        end
    end

    if #weight_map == 0 then
        ngx.log(ngx.ERR, "No healthy servers available in weighted_ip_hash")
        return nil, "No healthy servers available"
    end

    local client_ip = ngx.var.remote_addr or "127.0.0.1"
    local hash = ngx.crc32_long(client_ip) % total_weight

    for _, entry in ipairs(weight_map) do
        if hash < entry.cumulative_weight then
            ngx.log(ngx.DEBUG, "Selected server: ", entry.ip)
            return entry.ip, nil
        end
    end
end

return M
