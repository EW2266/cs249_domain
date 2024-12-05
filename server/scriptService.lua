local cjson = require "cjson"

local M = {}

-- load server_config.json
local function load_config(file_path)
    local file = io.open(file_path, "r")
    if not file then
        ngx.log(ngx.ERR, "Failed to open config file: ", file_path)
        return nil
    end

    local content = file:read("*a")
    file:close()

    local config = cjson.decode(content)
    if not config then
        ngx.log(ngx.ERR, "Failed to parse config file: ", file_path)
        return nil
    end

    return config
end

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

-- Load and validate
M.servers = load_config("./server/server_config.json")
if not M.servers or not validate_config(M.servers) then
    ngx.log(ngx.ERR, "Invalid server configuration. Aborting.")
    return
end

-- Perform HTTP health checks
function M.check_http_health(server_list, path)
    local max_retries = 3  -- Number of retry attempts
    local retry_delay = 500  -- Delay between retries (milliseconds)

    for _, server in ipairs(server_list) do
        local success = false
        local httpc = require "resty.http"

        for attempt = 1, max_retries do
            local http = httpc.new()
            local res, err = http:request_uri("http://" .. server.ip .. path, {
                method = "POST",
                timeout = 2000  -- Timeout in milliseconds
            })

            if res and res.status == 200 then
                success = true
                break  -- Exit retry loop on success
            else
                ngx.log(ngx.WARN, "HTTP health check failed for ", server.ip, " (Attempt ", attempt, "): ", err)
                if attempt < max_retries then
                    ngx.sleep(retry_delay / 1000)  -- Sleep between retries (convert ms to seconds)
                end
            end
        end

        if success then
            ngx.shared.health:set(server.ip, true)
        else
            ngx.log(ngx.ERR, "HTTP health check failed after ", max_retries, " attempts for ", server.ip)
            ngx.shared.health:set(server.ip, false)
        end
    end
end


-- Perform WebSocket health checks
function M.check_ws_health(server_list)
    local max_retries = 3  -- Number of retry attempts
    local retry_delay = 500  -- Delay between retries (milliseconds)

    for _, server in ipairs(server_list) do
        local success = false
        local host, port = server.ip:match("([^:]+):([^:]+)")

        for attempt = 1, max_retries do
            local sock = require "ngx.socket.tcp".new()
            
            local ok, err = sock:connect(host, tonumber(port))

            if ok then
                success = true
                sock:close()
                break  -- Exit retry loop on success
            else
                ngx.log(ngx.WARN, "WebSocket health check failed for ", server.ip, " (Attempt ", attempt, "): ", err)
                if attempt < max_retries then
                    ngx.sleep(retry_delay / 1000)  -- Sleep between retries (convert ms to seconds)
                end
            end
        end

        if success then
            ngx.shared.health:set(server.ip, true)
        else
            ngx.log(ngx.ERR, "WebSocket health check failed after ", max_retries, " attempts for ", server.ip)
            ngx.shared.health:set(server.ip, false)
        end
    end
end


-- Weighted IP hash using cumulative weights
function M.weighted_ip_hash(servers)
    local health = ngx.shared.health
    local total_weight = 0
    local weight_map = {}

    for _, server in ipairs(servers) do
        if health:get(server.ip) then
            total_weight = total_weight + server.weight
            table.insert(weight_map, { ip = server.ip, cumulative_weight = total_weight })
        end
    end

    if #weight_map == 0 then
        return nil, "No healthy servers available"
    end

    local client_ip = ngx.var.remote_addr
    local hash = ngx.crc32_long(client_ip) % total_weight

    for _, entry in ipairs(weight_map) do
        if hash < entry.cumulative_weight then
            return entry.ip, nil
        end
    end
end

return M
