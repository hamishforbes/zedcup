local ngx_log = ngx.log
local ngx_DEBUG = ngx.DEBUG
local ngx_ERR = ngx.ERR
local ngx_INFO = ngx.INFO
local ngx_WARN = ngx.WARN
local ngx_worker_pid = ngx.worker.pid

local _M = {
    _VERSION = "0.0.1",
    worker = {},
    cluster = {},
}

local zedcup = require("zedcup")
local GLOBALS = zedcup.globals()
local DEBUG  = GLOBALS.DEBUG

local utils = require("zedcup.utils")

local session = require("zedcup.session")


local function acquire_cluster_lock(key)
    if not key or type(key) ~= "string" then
        return error("[zedcup] Attempted to acquire cluster lock with bad key")
    end

    local session, err = session.get()
    if not session then
        ngx_log(ngx_ERR, "[zedcup] Failed to get session: ", err)
        return false, err
    end

    local consul, err = utils.consul_client()
    if not consul then
        return false, err
    end

    -- Attempt to acquire the lock
    local lock_key = GLOBALS.prefix.."/locks/"..key
    local res, err = consul:put_key(lock_key, "locked: "..ngx_worker_pid(), {acquire = session})

    if err or res.status ~= 200 or type(res.body) ~= "boolean" then
        -- Failed to acquire lock
        ngx_log(ngx_INFO,
                "[zedcup] Failed to acquire cluster lock: ", key, " ", session, " ", res.status, " ", err, " ", res.body
            )

        return false, res
    end

    if res.body == false then
        if DEBUG then
            ngx_log(ngx_DEBUG,
                "[zedcup] Missed cluster lock: ", key, " ", session, " ", res.status, " ", res.body
            )
        end

        return false
    end

    if DEBUG then
        ngx_log(ngx_DEBUG,  "[zedcup] Acquired cluster lock: ", key, " ", session)
    end

    return true
end
_M.cluster.acquire = acquire_cluster_lock


local function release_cluster_lock(key)
    if not key or type(key) ~= "string" then
        return error("[zedcup] Attempted to acquire cluster lock with bad key")
    end

    local session, err = session.get()
    if not session then
        ngx_log(ngx_ERR, "[zedcup] Failed to get session: ", err)
        return false, err
    end

    local consul, err = utils.consul_client()
    if not consul then
        return false, err
    end

    -- Attempt to release the lock
    local lock_key = GLOBALS.prefix.."/locks/"..key
    local res, err = consul:put_key(lock_key, "unlocked: "..ngx_worker_pid(), {release = session})

    if err then
        return false, err

    elseif res.status ~= 200 or res.body ~= true then
        -- Failed to acquire lock
        ngx_log(ngx_INFO, "[zedcup] Failed to release cluster lock: ", key, " ", res.status, " ", err)
        return false, res

    end

    if DEBUG then ngx_log(ngx_DEBUG, "[zedcup] Released cluster lock: ", key) end

    return true
end
_M.cluster.release = release_cluster_lock


local function acquire_worker_lock(key, ttl)
    if not key or type(key) ~= "string"  then
        return error("[zedcup] Attempted to acquire worker lock with bad key")
    end

    local global_config = zedcup.config()
    if not global_config then
        return nil, "Could not retrieve zedcup config"
    end

    local pid = ngx_worker_pid()
    local dict = GLOBALS.dicts["locks"]
    if not dict then
        error("[zedcup] could not find dict")
    end

    ttl = ttl or global_config.worker_lock_ttl

    key = "zedcup_worker_lock_"..key

    local lock, err = dict:add(key, pid, ttl)
    if lock then
        if DEBUG then ngx_log(ngx_DEBUG, "[zedcup] Acquired worker lock: ", key) end
        return true
    end

    if err == 'exists' then
        if DEBUG then ngx_log(ngx_DEBUG, "[zedcup] Missed worker lock: ", key) end
        return false

    else
        ngx_log(ngx_WARN, "[zedcup] Could not add worker lock key ", key, ": ", err)
        return false

    end
end
_M.worker.acquire = acquire_worker_lock


local function release_worker_lock(key)
    if not key or type(key) ~= "string" then
        return error("[zedcup] Attempted to release worker lock with bad key")
    end

    local dict = GLOBALS.dicts["locks"]
    if not dict then
        error("[zedcup] could not find dict")
    end

    key = "zedcup_worker_lock_"..key

    local pid, err = dict:get(key)
    if not pid then
        return false, err
    end

    if pid == ngx_worker_pid() then
        local ok, err = dict:delete(key)
        if not ok then
            ngx_log(ngx_ERR, "[zedcup] Failed to delete key '", key, "': ", err)
            return false
        end

        return true
    end

    return false
end
_M.worker.release = release_worker_lock


return _M
