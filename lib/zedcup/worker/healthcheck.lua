local ngx_log = ngx.log
local ngx_DEBUG = ngx.DEBUG
local ngx_ERR = ngx.ERR
local ngx_WARN = ngx.WARN
local str_sub = string.sub

local http_ok, resty_http = pcall(require, "resty.http")

local zedcup  = require("zedcup")
local GLOBALS = zedcup.globals()
local DEBUG =  GLOBALS.DEBUG

local utils = require("zedcup.utils")
local locks = require("zedcup.locks")

local _M = {
    _VERSION = "0.0.1",
}

local function _healthcheck_host(host, handler, state)
    local pool = host._pool

    -- No healthcheck configured
    if not host.healthcheck and not pool.healthcheck then return true end

    -- Healthcheck can be configured on the pool or the host
    local params = host.healthcheck or host._pool.healthcheck

    -- May not have any state on first check
    local host_state = {}
    if state then
        host_state = state[host._idx]
    end

    local last_check = host_state.last_check
    if last_check and (last_check + params.interval) <= ngx.now() then

        if DEBUG then
            ngx_log(ngx_DEBUG, "[zedcup (", handler.id, ")] Skipping healthcheck, already checked within window")
        end

        return true
    end

    if DEBUG then ngx_log(ngx_DEBUG, "[zedcup (", handler.id, ")] Healthchecking ", host._pool.name, "/", host.name) end

    local httpc = resty_http.new()

    -- Use healthcheck specific connect timeout or fallback to pool configuration
    httpc:set_timeout(params.timeout or pool.timeout)

    local ok, err = httpc:connect(host.host, host.port)
    if not ok then

        if DEBUG then ngx_log(ngx_DEBUG, "[zedcup (", handler.id, ")] Healthcheck connect failed ",
                host._pool.name, "/", host.name, ": ", err
            ) end
        -- Mark failed and emit
        handler.ctx.failed[pool._idx][host._idx] = true

        handler._emit(handler, "host_connect_error", { pool = pool, host = host, err = err, healthcheck = true })

        return false, err
    end

    if DEBUG then ngx_log(ngx_DEBUG, "[zedcup (", handler.id, ")] Healthcheck Connected: ",
            host._pool.name, "/", host.name
    ) end

    -- Use healthcheck specific read timeout or fallback to pool configuration
    httpc:set_timeout(params.read_timeout or pool.read_timeout)

    local res, err = httpc:request(params)
    if not res then
        if DEBUG then ngx_log(ngx_DEBUG, "[zedcup (", handler.id, ")] Healthcheck request error: ", err) end
        -- Mark failed and emit
        handler.ctx.failed[pool._idx][host._idx] = true

        handler._emit(handler, "host_request_error", { pool = pool, host = host, err = err, healthcheck = true })

        return false, err
    end

    if DEBUG then ngx_log(ngx_DEBUG, "[zedcup (", handler.id, ")] Healthcheck Response: ", res.status) end

    -- Discard body
    -- TODO: body content healthcheck
    if res.reader then
        local reader = res.reader

        repeat

            local chunk, err = reader(65536)
            if err then
                ngx_log(ngx_WARN,  "[zedcup (", handler.id, ")]  Healthcheck read error '",
                    host._pool.name, "/", host.name, "':",
                    err
                )

                break -- Don't consider this a failure
            end

        until not chunk
    end


    local status_codes = params.status_codes or pool.status_codes
    local status = tostring(res.status)

    if DEBUG then
        ngx_log(ngx_DEBUG, "[zedcup (", handler.id, ")] ", host._pool.name, "/", host.name,
            " Checking status ", status, " in ", require("cjson").encode(status_codes)
        )
    end

    -- Status codes are always 3 characters, so check for #xx or ##x
    if status_codes and
        (
            status_codes[status]
            or status_codes[str_sub(status, 1, 1)..'xx']
            or status_codes[str_sub(status, 1, 2)..'x']
        )
    then
        if DEBUG then
            ngx_log(ngx_DEBUG, "[zedcup (", handler.id, ")] Healthcheck got bad HTTP Status code: ", status)
        end

        -- Mark failed, emit event
        handler.ctx.failed[pool._idx][host._idx] = true

        local err =  "Bad status code: "..status
        handler._emit(handler, "host_request_error", { pool = pool, host = host, err = err, healthcheck = true })

        return false
    end

    -- TODO: increment rises if down
    return true
end


local function _healthcheck_instance(instance)
    local handler, err = zedcup.create_handler(instance)
    if not handler then
        if err then ngx_log(ngx_ERR, "[zedcup] Healthchecker could not create handler '", instance, "' :", err) end
        return false
    end

    local conf, err = handler:config()
    if not conf then
        if err then ngx_log(ngx_ERR, "[zedcup] Healthchecker could get config for '", instance, "' :", err) end
        return false
    end

    local state, err = handler:state()
    if err then
        ngx_log(ngx_ERR, "[zedcup] Healthchecker could get state for '", instance, "' :", err)
        return false
    end

    -- State can be nil
    if not state then
        state = {}
    end

    if not handler.ctx.failed then
        handler.ctx.failed = {}
    end

    -- Iterate over pools and launch a thread to healthcheck each host
    for pidx, pool in ipairs(conf.pools) do
        handler.ctx.failed[pidx] = {}
        utils.thread_map(pool.hosts, _healthcheck_host, handler, state[pidx])
    end

    -- Process healthcheck failures inline
    handler._process_host_errors(false, handler)

    return true
end


local function healthcheck(premature)
    if premature or not zedcup.initted() then
        return
    end

    local lock_key = "healthcheck"

     -- Acquire a full cluster lock
    if not locks.worker.acquire(lock_key) or not locks.cluster.acquire(lock_key) then
        return
    end

    local start = ngx.now()

    local instances = zedcup.instance_list()

    -- Run a thread to run healthchecks for each instance
    utils.thread_map(instances, _healthcheck_instance)

    local duration = ngx.now() - start

    if DEBUG then ngx_log(ngx_DEBUG, "[zedcup] Completed healthchecking in: ", duration) end

    -- Release both locks
    locks.worker.release(lock_key)
    locks.cluster.release(lock_key)

    return true
end
_M._healthcheck = healthcheck


function _M.run()
    if not http_ok then
        ngx_log(ngx_ERR, "[zedcup] Could not load resty.http, not running healthcheck worker")
        return false
    end

    return ngx.timer.every(zedcup.config().healthcheck_interval, healthcheck)
end


return _M
