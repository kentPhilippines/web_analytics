local _M = {}
local cjson = require "cjson"
local io = io
local os = os
local ngx = ngx
local shared = ngx.shared.analytics_cache

-- 配置
local ANALYTICS_DIR = "/var/log/nginx/analytics"
local RETENTION_DAYS = 30
local CACHE_EXPIRE = 300  -- 缓存5分钟

-- 工具函数
local function ensure_dir(dir)
    os.execute("mkdir -p " .. dir)
end

local function get_today()
    return os.date("%Y-%m-%d")
end

local function get_client_ip()
    local headers = ngx.req.get_headers()
    local ip = headers["X-Real-IP"]
    if not ip then
        ip = headers["X-Forwarded-For"]
        if ip then
            -- X-Forwarded-For 可能包含多个 IP，取第一个
            ip = string.match(ip, "^[^,]+")
        end
    end
    if not ip then
        ip = ngx.var.remote_addr
    end
    return ip
end

local function get_geo_info(ip)
    -- 从缓存获取
    local cache_key = "geo:" .. ip
    local cached = shared:get(cache_key)
    if cached then
        return cjson.decode(cached)
    end

    -- 使用 maxmind geoip2 数据库
    local geo = {
        country = "Unknown",
        city = "Unknown",
        region = "Unknown"
    }
    
    -- 这里可以添加 GeoIP2 查询代码
    -- 示例: local geoip = require("geoip2")
    
    -- 缓存结果
    shared:set(cache_key, cjson.encode(geo), CACHE_EXPIRE)
    return geo
end

-- 记录访问数据
function _M.record_visit()
    -- 处理 CORS 预检请求
    if ngx.req.get_method() == "OPTIONS" then
        ngx.header["Access-Control-Allow-Origin"] = "*"
        ngx.header["Access-Control-Allow-Methods"] = "POST, OPTIONS"
        ngx.header["Access-Control-Allow-Headers"] = "Content-Type, X-Requested-With"
        ngx.header["Access-Control-Max-Age"] = "1728000"
        ngx.header["Content-Type"] = "text/plain charset=UTF-8"
        ngx.header["Content-Length"] = "0"
        return ngx.exit(204)
    end

    -- 为实际请求添加 CORS 头
    ngx.header["Access-Control-Allow-Origin"] = "*"
    ngx.header["Access-Control-Allow-Methods"] = "POST, OPTIONS"
    ngx.header["Access-Control-Allow-Headers"] = "Content-Type, X-Requested-With"

    -- 获取请求数据
    ngx.req.read_body()
    local data = ngx.req.get_body_data()
    if not data then
        ngx.status = 400
        ngx.say(cjson.encode({error = "No data"}))
        return
    end

    -- 解析数据
    local success, visit = pcall(cjson.decode, data)
    if not success then
        return ngx.exit(400)
    end

    -- 添加服务器信息
    local ip = get_client_ip()
    local geo = get_geo_info(ip)
    
    visit.ip = ip
    visit.timestamp = ngx.localtime()
    visit.userAgent = ngx.var.http_user_agent
    visit.country = geo.country
    visit.city = geo.city
    visit.region = geo.region

    -- 准备存储目录
    local today = get_today()
    local log_dir = string.format("%s/%s", ANALYTICS_DIR, today)
    ensure_dir(log_dir)

    -- 存储数据
    local filename = string.format("%s/%s.log", log_dir, ngx.time())
    local file = io.open(filename, "w")
    if file then
        file:write(cjson.encode(visit))
        file:close()
        
        -- 更新缓存的统计数据
        local stats_key = "stats:" .. today
        local stats = shared:get(stats_key)
        if stats then
            stats = cjson.decode(stats)
            stats.total_visits = stats.total_visits + 1
            stats.unique_visitors[ip] = true
            stats.pages[visit.pageUrl] = (stats.pages[visit.pageUrl] or 0) + 1
            shared:set(stats_key, cjson.encode(stats), CACHE_EXPIRE)
        end
        
        ngx.say(cjson.encode({success = true}))
    else
        ngx.exit(500)
    end
end

-- 获取统计数据
function _M.get_stats()
    local today = get_today()
    local stats_key = "stats:" .. today
    
    -- 尝试从缓存获取
    local cached = shared:get(stats_key)
    if cached then
        ngx.say(cached)
        return
    end

    -- 重新计算统计数据
    local stats = {
        total_visits = 0,
        unique_visitors = {},
        pages = {},
        locations = {},
        hourly = {},
        daily = {}
    }

    -- 读取最近30天的数据
    for i = 0, RETENTION_DAYS - 1 do
        local date = os.date("%Y-%m-%d", os.time() - i * 86400)
        local dir = string.format("%s/%s", ANALYTICS_DIR, date)
        
        local files = io.popen("ls " .. dir .. "/*.log 2>/dev/null")
        if files then
            for file in files:lines() do
                local f = io.open(file, "r")
                if f then
                    local content = f:read("*all")
                    f:close()
                    
                    local success, visit = pcall(cjson.decode, content)
                    if success then
                        -- 更新统计
                        stats.total_visits = stats.total_visits + 1
                        stats.unique_visitors[visit.ip] = true
                        stats.pages[visit.pageUrl] = (stats.pages[visit.pageUrl] or 0) + 1
                        
                        local location = visit.country .. "-" .. visit.city
                        stats.locations[location] = (stats.locations[location] or 0) + 1
                        
                        -- 按小时统计
                        local hour = string.sub(visit.timestamp, 12, 13)
                        stats.hourly[hour] = (stats.hourly[hour] or 0) + 1
                        
                        -- 按天统计
                        local day = string.sub(visit.timestamp, 1, 10)
                        stats.daily[day] = (stats.daily[day] or 0) + 1
                    end
                end
            end
            files:close()
        end
    end

    -- 转换统计结果
    stats.unique_visitors = #table.keys(stats.unique_visitors)
    
    -- 缓存结果
    shared:set(stats_key, cjson.encode(stats), CACHE_EXPIRE)
    
    ngx.say(cjson.encode(stats))
end

-- 清理旧数据
function _M.cleanup()
    local cmd = string.format("find %s -type f -mtime +%d -delete", ANALYTICS_DIR, RETENTION_DAYS)
    os.execute(cmd)
end

return _M 