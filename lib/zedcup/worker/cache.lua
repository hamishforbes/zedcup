local ngx_log = ngx.log
local ngx_ERR = ngx.ERR
local ngx_DEBUG = ngx.DEBUG

local zedcup  = require("zedcup")
local GLOBALS = zedcup.globals()
local DEBUG =  GLOBALS.DEBUG

--local utils = require("zedcup.utils")

local _M = {
    _VERSION = "0.0.1",
}


local function cache_updates(premature)
    if not premature and zedcup.initted() then

        local ok, err = GLOBALS.cache:update()
        if not ok then
            ngx_log(ngx_ERR, "[zedcup] Cache update: ", err)
        end

    end
end


local function _run()
    local ok, err = ngx.timer.every(zedcup.config().cache_update_interval, cache_updates)
    if not ok then
        ngx_log(ngx_ERR, "[zedcup] Could not start cache worker: ", err)
    elseif DEBUG then
        ngx_log(ngx_DEBUG, "[zedcup] Started cache worker")
    end
end



function _M.run()
    return ngx.timer.at(0, _run)
end


return _M
