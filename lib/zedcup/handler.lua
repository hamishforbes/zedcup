local ngx_log = ngx.log
local ngx_DEBUG = ngx.DEBUG
local ngx_ERR = ngx.ERR
local ngx_WARN = ngx.WARN
local ngx_socket_tcp = ngx.socket.tcp
local tbl_insert = table.insert
local str_sub = string.sub

local http_ok, resty_http = pcall(require, "resty.http")

local zedcup  = require("zedcup")
local GLOBALS = zedcup.globals()
local DEBUG =  GLOBALS.DEBUG

local events = zedcup.events

local utils = require("zedcup.utils")
local tbl_copy_merge_defaults = utils.tbl_copy_merge_defaults
local tbl_copy = utils.tbl_copy


local _M = {
    _VERSION = "0.0.1",
}
local mt = { __index = _M }


local default_config = {
    pools = {},
    ssl   = false,
}

local pool_defaults = {
    up = true,
    method = "weighted_rr",
    timeout = 2000, -- socket connect timeout
    error_timeout = 60,
    max_errors = 3,
    min_rises  = 3, -- TODO: this
    hosts = {},

    -- HTTP defaults
    read_timeout = 10000,
    keepalive_timeout = 60000,
    keepalive_pool = 128,

}

local host_defaults = {
    up = true,
    weight = 1,
}

local healthcheck_defaults = {
    interval = 60,
    last_check = 0,
    method = "GET",
    path = "/",
    headers = {
        ["User-Agent"] = "zedcup/".. _M._VERSION.. " HTTP Check (lua)"
    },
    status_codes = { "5xx", "4xx" }
}


function _M.new(id)
    if not id then
        return nil, "No ID"
    end

    -- Create request level ctx entry
    local ctx = ngx.ctx
    if not ctx.zedcup then
        ctx.zedcup = { [id] = { failed = {} } }
    elseif not ctx.zedcup[id] then
        ctx.zedcup[id] = { failed = {} }
    end

    local self = {
        id           = id,
        cfg_prefix   = GLOBALS.prefix.."/instances/"..id.."/",
        state_prefix = GLOBALS.prefix.."/state/"..id.."/",
        cache        = GLOBALS["cache"],
        listeners    = {},
        op_data      = GLOBALS.op_data[id],
        ctx          = ctx.zedcup[id]
    }

    return setmetatable(self, mt)
end


function _M.bind(self, event, func)
    if not events[event] then
        return nil, "Event not found"
    end

    if type(func) ~= "function" then
        return nil, "Can only bind a function"
    end

    local listeners = self.listeners[event]
    if not listeners then
        self.listeners[event] = {}
        listeners = self.listeners[event]
    end

    tbl_insert(listeners, func)

    return true
end


local function emit(self, event, data)
    if DEBUG then ngx_log(ngx_DEBUG, "[zedcup (", self.id, ")] Emitting: ", event) end

     -- Execute local listeners bound to this handler only
    local listeners = self.listeners[event]
    if listeners then
        for _, func in ipairs(listeners) do
            local ok, err = pcall(func,data)
            if not ok then
                ngx_log(ngx_ERR, "[zedcup (", self.id, ")] Error running listener, event '", event,"': ", err)
            end
        end
    end

    -- Bubble up event to the global module
    zedcup._emit(event, self.id, data)
end
_M._emit = emit


local function _config(self)
    local id = self.id

    local consul, err = utils.consul_client()
    if not consul then
        return nil, err
    end

    if DEBUG then ngx_log(ngx_DEBUG, "[zedcup (", id, ")] Config key: ", self.cfg_prefix) end

    local res, err = consul:get_key(self.cfg_prefix, {recurse = true})
    if not res then
        return nil, err
    end

    if res.status ~= 200 then
        return nil, res
    end

    local conf = utils.entries2table(res.body, self.cfg_prefix)

    -- Merge default values for instance, pool and host
    conf = tbl_copy_merge_defaults(conf, default_config)

    for pidx, pool in ipairs(conf.pools) do
        pool._idx = pidx

        if not pool.name then
            pool.name = pidx
        end

        if pool.healthcheck == true then
            pool.healthcheck = tbl_copy(healthcheck_defaults)
        elseif type(pool.healthcheck) == "table" then
            pool.healthcheck = tbl_copy_merge_defaults(pool.healthcheck, healthcheck_defaults)
        end

        -- Convert status codes param from array to hash
        pool.status_codes = utils.array2hash(pool.status_codes)

        if pool.healthcheck then
            pool.healthcheck.status_codes = utils.array2hash(pool.healthcheck.status_codes)
        end


        conf.pools[pidx] = tbl_copy_merge_defaults(pool, pool_defaults)

        for hidx, host in ipairs(conf.pools[pidx].hosts) do
            host._idx = hidx
            host._pool = pool

            if not host.name then
                host.name = hidx
            end

            if host.healthcheck == true then
                host.healthcheck = tbl_copy_merge_defaults({}, healthcheck_defaults)
            elseif type(host.healthcheck) == "table" then
                host.healthcheck = tbl_copy_merge_defaults(host.healthcheck, healthcheck_defaults)
            end

            if host.healthcheck then
                host.healthcheck.status_codes = utils.array2hash(host.healthcheck.status_codes)
            end

            conf.pools[pidx].hosts[hidx] = tbl_copy_merge_defaults(host, host_defaults)
        end

    end

    -- Used to determine if the config has changed and clear cache later
    -- Must be shared across workers
    GLOBALS.dicts.cache:set("instance_index_"..self.id, res.headers["X-Consul-Index"])

    return conf
end


function _M.config(self)
    local config, err, hit_level = GLOBALS.cache:get(self.id.."_config", nil, _config, self)
    if err then
        ngx_log(ngx_ERR, "[zedcup (", self.id, ")] Failed to get Config: ", err)
        return nil, err
    end

    if DEBUG then ngx_log(ngx_DEBUG, "[zedcup (", self.id, ")] Config hit level: ", hit_level) end

    if hit_level ~= 1 then
        -- Reset op_data when we get config from higher cache levels
        if DEBUG then ngx_log(ngx_DEBUG, "[zedcup (", self.id, ")] Reset op data") end
        GLOBALS.op_data[self.id] = {}
        self.op_data = GLOBALS.op_data[self.id]
    end

    return utils.tbl_copy(config)
end


local function state_parse_cb(tbl, key, entry)
    tbl[key] = tonumber(entry["Value"])

    -- Combine the error count and last error fields into 1 consul key
    if key == "error_count" then
        tbl["last_error"] = tonumber(entry["Flags"])
    end
end


function _M.state(self)
    local id = self.id

    local consul, err = utils.consul_client()
    if not consul then
        return nil, err
    end

    if DEBUG then ngx_log(ngx_DEBUG, "[zedcup (", id, ")] State key: ", self.state_prefix) end

    local res, err = consul:get_key(self.state_prefix, {recurse = true})
    if not res then
        return nil, err
    end

    if res.status == 404 then
        return nil, nil
    end

    if res.status ~= 200 then
        return nil, res
    end

    return utils.entries2table(res.body, self.state_prefix, state_parse_cb)
end


function _M.incr_host_error_count(self, host)
    if not host then
        return nil, "host is nil"
    end

    local pool = host._pool
    local key = self.state_prefix..pool._idx.."/"..host._idx.."/error_count"

    local consul, err = utils.consul_client()
    if not consul then
        return false, err
    end

    local res, err = consul:get_key(key)
    if not res then
        return false, "Failed to retrieve state from consul: "..err
    end

    local error_count = 0
    local cas = nil

    if res.status == 200 then
        -- Stash the index for later
        cas = res.headers["X-Consul-Index"]
        error_count = tonumber(res.body[1].Value)

    elseif res.status ~= 404 then
        ngx_log(ngx_ERR, "[zedcup (", self.id, ")] Invalid status code from Consul: ", res.status)
        return false, res
    end

    if DEBUG then
        ngx_log(ngx_DEBUG, "Incrementing error count on ", pool.name, "/", host.name, " from: ", error_count)
    end

    error_count = error_count +1

    -- TODO: implement retry logic if CAS operation fails, is CAS worthwhile here?
    local res, err = consul:put_key(key, error_count, { cas = cas, flags = ngx.time() })
    if err then
        return false, err

    elseif res.status ~= 200 then
        return false, res

    end

    return error_count
end


function _M.reset_host_error_count(self, host)
    if not host then
        return nil, "host is nil"
    end

    local pool = host._pool
    local key = self.state_prefix..pool._idx.."/"..host._idx.."/error_count"

    local consul, err = utils.consul_client()
    if not consul then
        return false, err
    end

    local _, err = consul:delete_key(key)
    if err then
        return false, err
    end

    if DEBUG then ngx_log(ngx_DEBUG, "[zedcup (", self.id, ")] Reset error count on ", pool.name, "/", host.name) end

    return true
end


function _M.set_host_last_check(self, host)
    if not host then
        return nil, "host is nil"
    end

    local pool = host._pool
    local key = self.state_prefix..pool._idx.."/"..host._idx.."/last_check"

    local consul, err = utils.consul_client()
    if not consul then
        return false, err
    end

    local res, err = consul:put_key(key, ngx.time())
    if err then
        return false, err

    elseif res.status ~= 200 then
        return false, "Failed to update host last check: "..tostring(res.status)

    end

    if DEBUG then ngx_log(ngx_DEBUG, "[zedcup (", self.id, ")] Set last check time on ", pool.name, "/", host.name) end

    return true
end


local function set_host_status(self, host, status)
    if not host then
        return nil, "host is nil"
    end

    local pool = host._pool
    local key = self.cfg_prefix.."pools/"..pool._idx.."/hosts/"..host._idx.."/up"

    local consul, err = utils.consul_client()
    if not consul then
        return false, err
    end

    local res, err = consul:put_key(key, tostring(status))
    if err then
        return false, err

    elseif res.status ~= 200 then
        return false, tostring(res.status)

    end

    if DEBUG then
        ngx_log(ngx_DEBUG, "[zedcup (", self.id, ")] Set 'up: ", status ,"' on ", pool.name, "/", host.name)
    end

    return true
end


function _M.set_host_down(self, host)
    return set_host_status(self, host, false)
end


function _M.set_host_up(self, host)
    return set_host_status(self, host, true)
end


local function _persist_host_errors(premature, self)
    if premature then return end

    local conf, err = self:config()
    if not conf then
        return nil, err
    end

    local pools = conf.pools
    local failed = self.ctx.failed

    for pidx, error_hosts in pairs(failed) do -- pairs, this table can be sparse
        local pool = pools[pidx]
        local max_errors = pool.max_errors
        local hosts = pool.hosts

        for hidx, _ in pairs(error_hosts) do -- pairs, this table can be sparse
            local host = hosts[hidx]

            local error_count, err = self:incr_host_error_count(host)

            if err then
                if type(err) == "table" then
                    err = string.format("statuscode: %s, body: %s", err.status, err.body)
                end
                ngx_log(ngx_ERR, "[zedcup (", self.id, ")] Failed incrementing error count for ",
                    pool.name, "/", host.name,
                    ": ", err
                )

            elseif error_count >= max_errors and host.up == true then

                local ok, err = self:set_host_down(host)
                if not ok then
                    ngx_log(ngx_ERR,"[zedcup (", self.id, ")] Failed to set host down: ", err)
                else
                    ngx_log(ngx_DEBUG, "[zedcup (", self.id, ")] ", pool.name, "/", host.name, " is down")
                    emit(self, "host_down", {host = host, pool = pool})
                end

            end

        end
    end
end
_M._persist_host_errors = _persist_host_errors


function _M.persist_host_errors(self)
    -- Run in a background thread immediately after the request is done
    ngx.timer.at(0, _persist_host_errors, self)
end


local function _try_handshake(self, sock, host)
    local config = self:config()

    if not config or not config.ssl then
        return true
    end

    local ssl = config.ssl

    -- SSL is enabled with defaults
    if ssl == true then ssl = {} end

    local verify = true
    if ssl.verify == false then
        verify = false
    end

    local sni_name = ssl.sni_name or ngx.var.host

    if DEBUG then
        ngx_log(ngx_DEBUG, "[zedcup] TLS handshake ",
            host._pool.name, "/", host.name,
            ", verify: ", verify,
            ", sni_name: ", sni_name
        )
    end

    -- Do the handshake
    local session, err = sock:ssl_handshake(
                nil, -- TOOD: reuse session
                sni_name,
                verify
            )

    if not session then
        local pool = host._pool

        self.ctx.failed[pool._idx][host._idx] = true

        ngx_log(ngx_WARN,
            "[zedcup (", self.id, ")] Connect SSL handshake error '",
            pool.name, "/", host.name,
            " (", host.host, ":", host.port, ")': ",
            err
        )

        emit(self, "host_connect_error", {
            pool = pool,
            host = host,
            err = err,
            ssl = { verify = verify, sni_name = sni_name}
        })

        return false
    end

    return true
end


local function _try_connect(self, sock, host)
    if not host then
        return false
    end

    local pool = host._pool

    local connected, err
    if host.port then
        connected, err = sock:connect(host.host, host.port)
    else
        connected, err = sock:connect(host.host)
    end

    if not connected then
        -- Mark this host has having failed
        -- Will not be re-used in this request
        self.ctx.failed[pool._idx][host._idx] = true

        ngx_log(ngx_WARN,
            "[zedcup (", self.id, ")] Connect error '",
            pool.name, "/", host.name,
            " (", host.host, ":", host.port, ")': ",
            err
        )

        emit(self, "host_connect_error", { pool = pool, host = host, err = err })

        return false
    else
        if DEBUG then ngx_log(ngx_DEBUG, "[zedcup (", self.id, ")] Connected: ", host.name) end

        -- SSL Handshake if required
        if not _try_handshake(self, sock, host) then
            return false
        end

        -- Add the currently connected host to ctx
        self.ctx.connected_host = host

        emit(self, "host_connect", {pool = pool, host = host})

        return true
    end
end


local function connect(self, sock)
    local config, err = self:config()
    if not config then
        return nil, "Could not retrieve config: ".. (err or "")
    end

    -- A socket (or resty client module) can be passed in, otherwise create a socket
    if not sock then
        sock = ngx_socket_tcp()
    end

    -- Resty modules use set_timeout instead
    local set_timeout = sock.settimeout or sock.set_timeout

    local pools = config.pools
    if DEBUG then ngx_log(ngx_DEBUG, "[zedcup (", self.id, ")] connecting: \n", require("cjson").encode(pools) ) end

    local ctx = self.ctx

    -- Loop over pools and try each host
    for pidx, pool in ipairs(pools) do
        if DEBUG then ngx_log(ngx_DEBUG, "[zedcup (", self.id, ")] Trying pool: ", pool.name) end

        if not pool.up then
            ngx_log(ngx_ERR, "[zedcup (", self.id, ")] Pool '", pool.name, "' is down")
        else

            -- To keep track of which hosts we've already tried
            if not ctx.failed[pidx] then
                ctx.failed[pidx] = {}
            end

            -- Set connection timeout
            set_timeout(sock, pool.timeout)

            -- Get the load balancer function
            local ok, balancer = pcall(require, "zedcup.balance."..pool.method)
            if not ok then
                ngx_log(ngx_ERR, "[zedcup] Failed to load balancer ''", pool.method, "': ", balancer)
                return nil
            end

            -- Select a host according to the load balancer algorithm
            -- Try connecting until we succeed or fall through to the next pool
            repeat
                local host, err = balancer.select_host(self, pool)
                if err then
                    return nil, err
                end

                if _try_connect(self, sock, host) then
                    return sock
                end

            until not host

        end
    end

    -- Didnt find any pools with working hosts
    return nil, "No available upstream hosts"
end
_M.connect = connect


local function _try_request(self, params)
    local httpc = resty_http:new()
    self.httpc = httpc

    local httpc, err = connect(self, httpc)

    if not httpc then
        -- Could not connect
        return false, err
    end

    local host = self.ctx.connected_host
    local pool = host._pool

    -- Connected, set the read timeout
    httpc:set_timeout(pool.read_timeout)

    if DEBUG then ngx_log(ngx_DEBUG, "[zedcup (", self.id, ")] Sending HTTP request") end

    local res, err = httpc:request(params)

    if not res then
        if DEBUG then ngx_log(ngx_DEBUG, "[zedcup (", self.id, ")] HTTP Request failed: ", err) end

        -- Mark failed, emit event
        self.ctx.failed[pool._idx][host._idx] = true

        emit(self, "host_request_error", { pool = pool, host = host, err = err })

        return nil, err
    end

    -- Check status codces
    local status_codes = pool.status_codes or {}
    local status = tostring(res.status)

    -- Status codes are always 3 characters, so check for #xx or ##x
    if status_codes[status]
        or status_codes[str_sub(status, 1, 1)..'xx']
        or status_codes[str_sub(status, 1, 2)..'x']
    then
        if DEBUG then ngx_log(ngx_DEBUG, "[zedcup (", self.id, ")] Bad HTTP Status code: ", status) end

        -- Mark failed, emit event
        self.ctx.failed[pool._idx][host._idx] = true

        local err =  "Bad status code: "..status
        emit(self, "host_request_error", { pool = pool, host = host, err = err })

        return nil, err
    end

    if DEBUG then ngx_log(ngx_DEBUG, "[zedcup (", self.id, ")] Successful HTTP request: ", res.status) end

    return res
end


function _M.request(self, params)
    if not http_ok then
        return nil, "Could not load resty.http"
    end

    local body_reusable = (type(params.body) ~= 'function')

    local res, err

    repeat
        res, err = _try_request(self, params)

        -- Request succeed
        if res then
            return res
        end

        -- Cannot retry the HTTP request
        if not body_reusable then
            if DEBUG then ngx_log(ngx_DEBUG, "[zedcup (", self.id, ")] Could not retry HTTP request") end
            return res, err
        end

    -- try_request returns false when no more connections are possible
    -- nil when there's a request error and we should try again with a different host
    until res == false

    if DEBUG then ngx_log(ngx_DEBUG, "[zedcup (", self.id, ")] Could not complete HTTP request") end

    return res, err
end


function _M.get_client_body_reader(self, ...)
    return self.httpc:get_client_body_reader(...)
end


function _M.set_keepalive(self, ...)
    local connected_host = self.ctx.connected_host

    local keepalive_timeout = select(1, ...)
    local keepalive_pool = select(2, ...)

    if not keepalive_timeout and connected_host then
        keepalive_timeout = self.ctx.connected_host._pool.keepalive_timeout
    end

    if not keepalive_pool and connected_host then
        keepalive_pool = self.ctx.connected_host._pool.keepalive_timeout
    end

    return self.httpc:set_keepalive(keepalive_timeout, keepalive_pool)
end


function _M.get_reused_times(self, ...)
    return self.httpc:getreusedtimes(...)
end


function _M.close(self, ...)
    return self.httpc:close(...)
end


return _M
