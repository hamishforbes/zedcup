local ngx_log = ngx.log
local ngx_DEBUG = ngx.DEBUG
local ngx_ERR = ngx.ERR

local str_sub = string.sub
local str_find = string.find

local zedcup  = require("zedcup")
local GLOBALS = zedcup.globals()
local DEBUG =  GLOBALS.DEBUG

local utils = require("zedcup.utils")
local locks = require("zedcup.locks")

local _M = {
    _VERSION = "0.0.1",
}


local function watch_key(key, index)
    local wait = zedcup.config().consul_wait_time
    if DEBUG then ngx_log(ngx_DEBUG, "[zedcup] Waiting ", wait ,"s for ",index," on ", key) end

    local consul, err = utils.consul_client()
    if not consul then
        return nil, err
    end

    local res, err = consul:get_key(key, {
            recurse = true,
            index = index,
            wait = wait
        })

    if not res or err then
        return false, err
    end

    if res.status ~= 200 then
        return false, string.format("status: %s, body: %s", res.status, res.body)
    end

    if DEBUG then ngx_log(ngx_DEBUG, "[zedcup] Got ",res.headers["X-Consul-Index"]," on ", key) end

    if res.headers["X-Consul-Index"] == index then
        -- No change
        return nil
    end

    return res
end


local function _config_watcher()
    local dict = GLOBALS.dicts.cache
    local idx = dict:get("config_index")

    local config_key = GLOBALS.prefix .. "/config/"
    local res, err = watch_key(config_key, idx)

    if res == false then
        ngx_log(ngx_ERR, "[zedcup] Global watcher error: ", err)
        return false
    end

    if res == nil then
        if DEBUG then ngx_log(ngx_DEBUG, "[zedcup] Config watcher no change") end
        return nil
    end

    if DEBUG then ngx_log(ngx_DEBUG, "[zedcup] Config changed, clearing cache") end

    -- Config has changed, clear the cache entry to force a refresh
    -- TODO: set cache here instead?
    local ok, err = GLOBALS.cache:delete("config")
    if not ok then
        ngx_log(ngx_ERR, "[zedcup] Config cache clear: ", err)
    end

    -- Use this index for the next watch
    dict:set("config_index", res.headers["X-Consul-Index"])

    return true
end
_M._config_watcher = _config_watcher


local function prefix_indices(entries, prefix)
    -- Iterate over the entries
    -- Find the highest ModifyIndex value for each sub-prefix
    local magic_len = #(prefix or "")+1

    local indices = {}

    for _, entry in pairs(entries) do

        local k  = str_sub(entry["Key"], magic_len)
        k = str_sub(k, 1, str_find(k, "/", 1, true) - 1)

        if DEBUG then ngx.log(ngx.DEBUG, "[zedcup] ", entry["Key"], " : ", entry["ModifyIndex"]) end

        if not indices[k] or indices[k] < entry["ModifyIndex"] then
            indices[k] = entry["ModifyIndex"]
        end

    end

    return indices
end


local function instance_compare(arr1, arr2)
    -- Check every entry in arr1 also exists in arr2
    for _, v in ipairs(arr1) do
        if not arr2[v] then
            return false
        end
    end

    -- Check every entry in arr2 also exists in arr2
    for _, v in ipairs(arr2) do
        if not arr1[v] then
            return false
        end
    end

    return true
end


local function _instance_watcher()
    local dict = GLOBALS.dicts.cache
    local idx = dict:get("instances_index")

    local config_key = GLOBALS.prefix .. "/instances/"
    local res, err = watch_key(config_key, idx)

    if res == false then
        ngx_log(ngx_ERR, "[zedcup] Instance watcher error: ", err)
        return false
    end

    if res == nil then
        if DEBUG then ngx_log(ngx_DEBUG, "[zedcup] Instance watcher no change") end
        return nil
    end

    -- Config has changed, clear the cache entry to force a refresh
    local cur_instances = zedcup.instance_list()
    local new_instances = zedcup._instance_list()

    if not instance_compare(cur_instances, new_instances) then
        if DEBUG then ngx_log(ngx_DEBUG, "[zedcup] Instances changed, updating list cache") end

        local ok, err = GLOBALS.cache:set("instance_list", nil, new_instances)
        if not ok then
            ngx_log(ngx_ERR, "[zedcup] Instance list set: ", err)
        end

    elseif DEBUG then ngx_log(ngx_DEBUG, "[zedcup] No instances change") end


    -- Determine which instance caches need clearing
    -- TODO: set new values instead?
    local indices = prefix_indices(res.body, config_key)

    for instance, index in pairs(indices) do
        local instance_key = "instance_index_"..instance
        local cur_idx = dict:get(instance_key)

        if DEBUG then
            ngx_log(ngx_DEBUG, "[zedcup] Instance: ", instance,
                ", new idx: ", index,
                ", cur idx: ", cur_idx
            )
        end

        if cur_idx and tonumber(cur_idx) < tonumber(index) then
            if DEBUG then ngx_log(ngx_DEBUG, "[zedcup] clearing cache for ", instance) end

            local ok, err = GLOBALS.cache:delete(instance.."_config")
            if not ok then
                ngx_log(ngx_ERR, "[zedcup] Instance config clear ", instance, ": ", err)
            end

            -- Remove the cached index
            -- If the instance doesn't repopulate itself before the next run we shouldn't clear it again
            dict:delete(instance_key)

        end

    end

    -- Use this index for the next watch
    dict:set("instances_index", res.headers["X-Consul-Index"])

   return true
end
_M._instance_watcher = _instance_watcher


local function watcher(premature, func, lock_key, attempt)
    if premature or not zedcup.initted() then
        return
    end

    local delay = zedcup.config().watcher_interval

    if not locks.worker.acquire(lock_key) then
        return ngx.timer.at(delay, watcher, func, lock_key)
    end

    local ok = func()

    if ok == false then
        attempt = (attempt or 0) + 1
        -- An error occurred, delay retry
        delay = utils.error_delay(attempt)
    else
        -- No error, re-watch immediately
        attempt = 0
        delay = 0
    end

    locks.worker.release(lock_key)
    return ngx.timer.at(delay, watcher, func, lock_key, attempt)
end


function _M.run()
    local ok, err = ngx.timer.at(zedcup.config().watcher_interval, watcher, _config_watcher, "config_watcher")
    if not ok then
        ngx.log(ngx.ERR, "[zedcup] Failed to start global config watcher: ", err)
    end

    local ok, err = ngx.timer.at(zedcup.config().watcher_interval, watcher, _instance_watcher, "instance_watcher")
    if not ok then
        ngx.log(ngx.ERR, "[zedcup] Failed to start instance watcher: ", err)
    end
end


return _M
