local ngx_log = ngx.log
local ngx_DEBUG = ngx.DEBUG
local ngx_worker_pid = ngx.worker.pid
local str_sub = string.sub

local _M = {
    _VERSION = "0.0.1",
}

local zedcup = require("zedcup")
local GLOBALS = zedcup.globals()
local DEBUG  = GLOBALS.DEBUG

local utils = require("zedcup.utils")

local sessionid, session_expires

local function destroy()
    if not sessionid then return nil, "No session to destroy" end

    local consul, err = utils.consul_client()
    if not consul then
        return nil, err
    end

    local res, err = consul:put("/session/destroy/"..sessionid, "")

    if err or res.status ~= 200 or res.body ~= true then
        return nil, err
    end

    sessionid, session_expires = nil, nil

    return true
end
_M.destroy = destroy


local function renew()
    if not sessionid then return nil, "No session to renew" end

    -- Session doesn't need renewing
    if session_expires > (ngx.time() + 10) then
        return nil
    end

    if DEBUG then
        ngx_log(ngx_DEBUG, "[zedcup] Renewing session ", sessionid, " expiry: ", session_expires, " now: ", ngx.time())
    end

    local consul, err = utils.consul_client()
    if not consul then
        return false, err
    end

    local res, err = consul:put("/session/renew/"..sessionid, "")

    if err or res.status ~= 200 then
        sessionid = nil -- Reset session if we fail to renew
        return false, err, res
    end

    local ttl = res.body[1]["TTL"]

    session_expires = ngx.time() + tonumber(str_sub(ttl, 1, -2))

    return true
end
_M.renew = renew


local function create()
    local global_config = zedcup.config()

    local consul, err = utils.consul_client()
    if not consul then
        return nil, err
    end

    if DEBUG then ngx_log(ngx_DEBUG, "[zedcup] Creating New Consul session") end

    local res, err = consul:put("/session/create", {
        Name = "zedcup: "..ngx_worker_pid(),
        TTL = global_config.session_ttl.."s",
        Behavior = "delete"
    })

    if err or res.status ~= 200 then
        return nil, err
    end

    sessionid = res.body["ID"]
    session_expires = ngx.time() + global_config.session_ttl

    if DEBUG then ngx_log(ngx_DEBUG, "[zedcup] Registering worker session: ", sessionid) end

    local res, err = consul:put_key(GLOBALS.prefix.."/registry/"..sessionid, "", {
        acquire = sessionid
    })

    if err or res.status ~= 200 then
        return nil, err
    end

    return true
end


local function get()
    if sessionid and session_expires > ngx.time() then
        return sessionid
    end

    local ok, err  = create()
    if not ok then
        return nil, err
    end

    if DEBUG then ngx_log(ngx_DEBUG,  "[zedcup] Session: ", sessionid, " Expires: ", session_expires) end

    return sessionid
end
_M.get = get


-- Test helper
_M._clear = function() sessionid, session_expires = nil, nil end

return _M
