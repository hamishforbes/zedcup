-- Default SHM state storage backend

local tbl_insert = table.insert
local tbl_sort = table.sort
local ngx_log = ngx.log
local ngx_DEBUG = ngx.DEBUG
local ngx_ERR = ngx.ERR
local ngx_INFO = ngx.INFO
local shared = ngx.shared
local phase = ngx.get_phase
local ngx_worker_pid = ngx.worker.pid

local cjson = require('cjson')
local cjson_encode = cjson.encode
local cjson_decode = cjson.decode
local resty_lock = require('resty.lock')

local safe_json = function(func, data)
    local ok, ret = pcall(func, data)
    if ok then
        return ret
    else
        ngx_log(ngx_ERR, ret)
        return nil, ret
    end
end

local json_decode = function(data)
    return safe_json(cjson_decode, data)
end


local json_encode = function(data)
   return safe_json(cjson_encode, data)
end


local _M = {
    _VERSION = "0.09",
    background_period = 10,
    background_timeout = 120
}

local mt = { __index = _M }

local log_prefix = "[Resty Upstream (SHM)] "


function _M.new(_, upstream, opts)
    local dict = shared[opts.dict]
    if not dict then
        return nil, "Shared dictionary not found"
    end

    local id = upstream.id

    local self = {
        upstream = upstream, -- parent upstream.socket object
        id = upstream.id,
        dict_name = opts.dict,
        dict = dict,

        -- Create unique dictionary keys for this instance of upstream
        pools_key       = id..'_pools',
        background_flag = id..'_background_running',
        priority_key    = id..'_priority_index',
        lock_key        = id..'_lock',
    }

    local configured = true
    if dict:get(self.pools_key) == nil then
        dict:set(self.pools_key, json_encode({}))
        configured = false
    end

    return setmetatable(self, mt), configured
end


function _M.get_background_lock(self)
    local pid = ngx_worker_pid()
    local dict = self.dict

    local lock, err = dict:add(self.background_flag, pid, self.background_timeout)
    if lock then
        return true
    end

    if err == 'exists' then
        return false
    else
        ngx_log(ngx_DEBUG, log_prefix, "Could not add background lock key in pid #", pid)
        return false
    end
end


function _M.release_background_lock(self)
    local dict = self.dict

    local pid, err = dict:get(self.background_flag)
    if not pid then
        self:log(ngx_ERR, "Failed to get key '", self.background_flag, "': ", err)
        return
    end

    if pid == ngx_worker_pid() then
        local ok, err = dict:delete(self.background_flag)
        if not ok then
            ngx_log(ngx_ERR, log_prefix, "Failed to delete key '", self.background_flag, "': ", err)
        end
    end
end


local function get_lock_obj(self)
    local ctx = self.upstream:ctx()
    if not ctx.lock then
        local err
        ctx.lock, err = resty_lock:new(self.dict_name)
        if err then
            return nil, err
        end
    end

    return ctx.lock
end


function _M.get_pools(self)
    local ctx =  self.upstream:ctx()
    if ctx.pools == nil then
        local pool_str, err = self.dict:get(self.pools_key)
        if not pool_str then
            return nil, err
        end

        local pools, err = json_decode(pool_str)
        if not pools then
            return nil, err
        end

        ctx.pools = json_decode(pool_str)
    end

    return ctx.pools
end


function _M.get_locked_pools(self)
    if phase() == 'init' then
        return self:get_pools()
    end

    local lock = get_lock_obj(self)
    local ok, err = lock:lock(self.lock_key)

    if ok then
        local pool_str, err = self.dict:get(self.pools_key)
        if not pool_str then
            return nil, err
        end

        return json_decode(pool_str)
    else
        ngx_log(ngx_INFO, log_prefix, "Failed to lock pools: ", err)
    end

    return ok, err
end


function _M.unlock_pools(self)
    if phase() == 'init' then
        return true
    end

    local lock = get_lock_obj(self)
    local ok, err = lock:unlock(self.lock_key)
    if not ok then
        ngx_log(ngx_ERR, log_prefix, "Failed to release pools lock: ", err)
    end

    return ok, err
end


function _M.get_priority_index(self)
    local ctx = self.upstream:ctx()

    if ctx.priority_index == nil then
        local priority_str, err = self.dict:get(self.priority_key)
        if not priority_str then
            return nil, err
        end

        local priority_index, err = json_decode(priority_str)
        if not priority_index then
            return nil, err
        end

        ctx.priority_index = priority_index
    end

    return ctx.priority_index
end


function _M.save_pools(self, pools)
    pools = pools or {}
    self.upstream:ctx().pools = pools

    local serialised, err = json_encode(pools)
    if not serialised then
        return nil, err
    end

    return self.dict:set(self.pools_key, serialised)
end


function _M.sort_pools(self, pools)
    -- Create a table of priorities and a map back to the pool
    local priorities = {}
    local map = {}

    for id, p in pairs(pools) do
        map[p.priority] = id
        tbl_insert(priorities, p.priority)
    end
    tbl_sort(priorities)

    local sorted_pools = {}
    for _, pri in ipairs(priorities) do
        tbl_insert(sorted_pools, map[pri])
    end

    local serialised = json_encode(sorted_pools)
    return self.dict:set(self.priority_key, serialised)
end

return _M
