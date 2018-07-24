local ngx_log = ngx.log
local ngx_DEBUG = ngx.DEBUG
local ngx_ERR = ngx.ERR

local zedcup  = require("zedcup")
local GLOBALS = zedcup.globals()
local DEBUG =  GLOBALS.DEBUG

local utils = require("zedcup.utils")
local zedcup_session = require("zedcup.session")
local locks = require("zedcup.locks")


local _M = {
    _VERSION = "0.0.1",
}


local function renew(premature, attempt)
    if premature then return end
    attempt = attempt or 1

    local global_config = zedcup.config()

    local delay    = global_config.session_renew_interval
    local lock_key = "session_renew"

    -- Acquire worker level lock
    if not locks.worker.acquire(lock_key) then
        -- Reschedule the job
        if DEBUG then ngx_log(ngx_DEBUG, "[zedcup] Running session worker again in ", delay) end
        return ngx.timer.at(delay, renew)
    end

    -- Got the lock, renew the session
    local ok, err, res = zedcup_session.renew()

    -- Release the lock
    locks.worker.release(lock_key)

    if ok == false then
        -- Failed, delay retry
        delay = utils.error_delay(attempt)

        if not err and res then
            err = res.body
        end

        ngx_log(ngx_ERR, "[zedcup] Session renew failed, retrying in ", delay, "s :", err)
        return ngx.timer.at(delay, renew, attempt+1)
    end

    -- Renew again before the session expires
    if DEBUG then ngx_log(ngx_DEBUG, "[zedcup] Running session worker again in ", delay) end
    return ngx.timer.at(delay, renew)
end


function _M.run()
    return ngx.timer.at(0, renew)
end


return _M