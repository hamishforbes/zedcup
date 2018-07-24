local ngx_log = ngx.log
local ngx_DEBUG = ngx.DEBUG
local ngx_ERR = ngx.ERR

local zedcup  = require("zedcup")
local GLOBALS = zedcup.globals()
local DEBUG =  GLOBALS.DEBUG

local utils = require("zedcup.utils")
local locks = require("zedcup.locks")

local _M = {
    _VERSION = "0.0.1",
}

local function _revive_instance(instance)
    if DEBUG then ngx_log(ngx_DEBUG, "[zedcup] Reviving offline hosts in ", instance) end

    local handler, err = zedcup.create_handler(instance)
    if not handler then
        if err then ngx_log(ngx_ERR, "[zedcup] Could not create handler '", instance, "' :", err) end
        return false
    end

    local state, err = handler:state()
    if not state then
        if type(err) == "table"  then
            -- Consul response object
            if err.status ~= 404 then
                ngx_log(ngx_ERR, "[zedcup] Could not get state '", instance, "' :", err.status, " ", err.body)

                return false
            end
        else
            ngx_log(ngx_ERR, "[zedcup] Could not get state '", instance, "' :", err)
             return false
        end

        if DEBUG then ngx_log(ngx_DEBUG, "[zedcup] No state for '", instance, "' skipping") end
        return nil -- No state is a legitimate scenario
    end

    local config, err = handler:config()
    if not config then
        if err then ngx_log(ngx_ERR, "[zedcup] Could not get config '", instance, "' :", err) end
        return false
    end

    local now = ngx.time()

    for pidx, hosts in pairs(state) do
        local pool = config.pools[pidx]

        if DEBUG then ngx_log(ngx_DEBUG, "[zedcup (", instance, ")] Checking ", pool.name ) end

        local error_timeout = pool.error_timeout

        for hidx, host_state in pairs(hosts) do
            local host = pool.hosts[hidx]

            if host_state.last_error then
                if DEBUG then
                    ngx_log(ngx_DEBUG, "[zedcup (", instance, ")] Checking ", pool.name, "/", host.name,
                        " up: ", host.up, "(", type(host.up), ")",
                        " last_error: ", host_state.last_error,
                        " timeout: ", error_timeout,
                        " now: ",now
                    )
                end


                if (host_state.last_error + error_timeout) < now then
                    -- Last error was beyond the error timeout, reset the state
                    if DEBUG then
                        ngx_log(ngx_DEBUG, "[zedcup (", instance, ")] Reset error count for ",
                             pool.name, "/", host.name
                        )
                    end

                    local ok, err = handler:reset_host_error_count(host)

                    if not ok then
                        ngx_log(ngx_ERR,"[zedcup (", instance, ")] Failed to reset host error count: ", err)

                    elseif host.up == false then

                        -- Host is down too, set it up
                        local ok, err = handler:set_host_up(host)
                        if not ok then
                            ngx_log(ngx_ERR,"[zedcup (", instance, ")] Failed to set host up: ", err)

                        else
                            ngx_log(ngx_DEBUG, "[zedcup (", instance, ")] ", pool.name, "/", host.name, " is up")

                            handler:_emit("host_up", {host = host, pool = pool})

                        end

                    end
                end
            end

        end

    end

end


local function revive(premature)
    if premature or not zedcup.initted() then
        return
    end

    local lock_key = "revive"

     -- Acquire a full cluster lock
    if not locks.worker.acquire(lock_key) or not locks.cluster.acquire(lock_key) then
        return
    end

    local instances = zedcup.instance_list()

    -- Run a thread for each instance
    utils.thread_map(instances, _revive_instance)

    -- Release both locks
    locks.worker.release(lock_key)
    locks.cluster.release(lock_key)

    return true
end
_M._revive = revive


function _M.run()
    return ngx.timer.every(zedcup.config().host_revive_interval, revive)
end


return _M
