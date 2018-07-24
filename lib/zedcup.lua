local ngx_log = ngx.log
local ngx_DEBUG = ngx.DEBUG
local ngx_ERR = ngx.ERR
local str_sub = string.sub
local str_find = string.find
local tbl_insert = table.insert

local mlcache = require("resty.mlcache")
local utils = require("zedcup.utils")

local DEBUG = false

local _M = {
    _VERSION = "0.0.1",
}

local default_global_config = {
    host_revive_interval = 10,
    cache_update_interval = 1,
    healthcheck_interval = 10,
    watcher_interval = 10,
    session_renew_interval = 10,
    session_ttl = 30,
    worker_lock_ttl = 30,
    consul_wait_time = 600, -- Default Consul max
}

local events = {
    ["host_connect"] = true,
    ["host_connect_error"] = true,
    ["host_request_error"] = true,
    ["host_up"] = true,
    ["host_down"] = true,
}
_M.events = events

local GLOBALS = {
    consul_config = nil,
    prefix        = nil,
    dicts         = {},
    dict_names    = {},
    listeners     = {},
    op_data       = {},
    DEBUG         = false,
}

local INIT = false

_M._debug = function(d) DEBUG, GLOBALS.DEBUG = d, d end


-- Initialise zedcup with enough configuration to connect to consul and initialise cache(s)
function _M.init(opts)
    opts = utils.tbl_copy_merge_defaults(opts or {}, {
        prefix = "zedcup",
        consul = {},
        dicts  = {
            cache = "zedcup_cache",
            locks = "zedcup_locks",
            ipc   = "zedcup_ipc",
        }
    })

    GLOBALS.consul_config = opts.consul

    GLOBALS.prefix = opts.prefix

    for key, name in pairs(opts.dicts) do
        if not ngx.shared[name] then
            error("[zedcup] ", key ," dictionary not found: ", name)
        end

        GLOBALS.dicts[key]      = ngx.shared[name]
        GLOBALS.dict_names[key] = name
    end

    local cache, err = mlcache.new(
            "zedcup",
            GLOBALS.dict_names.cache,
            {
                ipc_shm   = GLOBALS.dict_names.ipc,
                shm_locks = GLOBALS.dict_names.locks,
            }
        )
    if not cache then
        error("[zedcup] Failed to initialise cache: "..tostring(err))
    end

    GLOBALS["cache"] = cache
    INIT = true

    if DEBUG then ngx_log(ngx_DEBUG, "[zedcup] Initialised") end

    return true
end


function _M.initted() return INIT end


function _M.run_workers()
    if DEBUG then ngx_log(ngx_DEBUG, "[zedcup] Starting workers") end

    -- cache updates (no lock)
    local ok, err = require("zedcup.worker.cache").run()
    if not ok then
        ngx_log(ngx_ERR, "[zedcup] Failed to start cache worker: ", err)
    end

    -- watch config (worker lock)
    local ok, err = require("zedcup.worker.watcher").run()
    if not ok then
        ngx_log(ngx_ERR, "[zedcup] Failed to start config watcher: ", err)
    end

    -- healthchecks (cluster lock)
    local ok, err = require("zedcup.worker.healthcheck").run()
    if not ok then
        ngx_log(ngx_ERR, "[zedcup] Failed to start healthcheck worker: ", err)
    end

    -- revive hosts (cluster lock)
    local ok, err = require("zedcup.worker.revive").run()
    if not ok then
        ngx_log(ngx_ERR, "[zedcup] Failed to start revive worker: ", err)
    end

    -- session renewal
    local ok, err = require("zedcup.worker.session").run()
    if not ok then
        ngx_log(ngx_ERR, "[zedcup] Failed to start session worker: ", err)
    end
end


function _M.globals()
    return GLOBALS
end


local function _config()
    local consul, err = utils.consul_client()
    if not consul then
        return nil, err
    end

    local config_key = GLOBALS.prefix .. "/config/"
    if DEBUG then ngx_log(ngx_DEBUG, "[zedcup] Config key: ", config_key) end

    local res, err = consul:get_key(config_key, {recurse = true})
    if not res then
        return nil, err
    end

    if res.status == 404 then
        if DEBUG then ngx_log(ngx_DEBUG, "[zedcup] Config is 404") end
        return {}
    end

    if res.status ~= 200 then
        return nil, err
    end

    GLOBALS.dicts.cache:set("instances_index", res.headers["X-Consul-Index"])

    return utils.entries2table(res.body, config_key)
end


function _M.config()
    local config, err, hit_level = GLOBALS.cache:get("config", nil, _config)
    if err then
        ngx_log(ngx_ERR, "[zedcup] Failed to get config: ", err)
        return nil, err
    end

    if DEBUG then ngx_log(ngx_DEBUG, "[zedcup] Config hit level: ", hit_level) end

    return utils.tbl_copy_merge_defaults(config, default_global_config)
end


function _M.configure(config)
    if not config then
        return nil, "Invalid config"
    end

    local consul, err = utils.consul_client()
    if not consul then
        return nil, err
    end

    local conf_prefix = GLOBALS.prefix .. "/config/"

    -- Set cluster config into consul
    -- Clear the  config as the first step in the transaction
    local txn_payload = {
        {
            KV = {
                Verb = "delete-tree",
                Key = conf_prefix
            }
        },
    }

    -- Cnnvert the table into a set of txn commands
    utils.table2txn(conf_prefix, config, txn_payload)

    --if DEBUG then ngx_log(ngx_DEBUG, "Configure Payload:\n", require("cjson").encode(txn_payload)) end
    local res, err = consul:txn(txn_payload)
    if not res then
        return nil, err
    end

    --if DEBUG then ngx_log(ngx_DEBUG, "Configure Res:", res.status, "\n", require("cjson").encode(res.body)) end

    local err = res.body["Errors"]
    if err ~= ngx.null then
        return nil, err
    end

    --ngx.log(ngx.DEBUG, json_encode(res.body))
    return true
end


function _M.configure_instance(instance, config)
    if not config then
        return nil, "Invalid config"
    end

    if not instance then
        return nil, "Invalid instance ID"
    end

    local consul, err = utils.consul_client()
    if not consul then
        return nil, err
    end

    local conf_prefix = GLOBALS.prefix .. "/instances/"..instance.."/"

    -- Clear the instance config as the first step in the transaction
    -- Clear transient state too
    local txn_payload = {
        {
            KV = {
                Verb = "delete-tree",
                Key = conf_prefix
            }
        },
        {
            KV = {
                Verb = "delete-tree",
                Key = GLOBALS.prefix.."/state/"..instance
            }
        },
    }

    -- Cnnvert the table into a set of txn commands
    utils.table2txn(conf_prefix, config, txn_payload)

    --if DEBUG then ngx_log(ngx_DEBUG, "Instance Payload:\n", require("cjson").encode(txn_payload)) end
    local res, err = consul:txn(txn_payload)
    if not res then
        return nil, err
    end

    --if DEBUG then ngx_log(ngx_DEBUG, "Instance Res:", res.status, "\n", require("cjson").encode(res.body)) end

    local err = res.body["Errors"]
    if err ~= ngx.null then
        return nil, err
    end

    -- Reset op data
    GLOBALS.op_data[instance] = {}

    --ngx.log(ngx.DEBUG, json_encode(res.body))
    return true
end


local function _instance_list()
    local consul, err = utils.consul_client()
    if not consul then
        return nil, err
    end

    local instance_key = GLOBALS.prefix .. "/instances/"
    if DEBUG then ngx_log(ngx_DEBUG, "[zedcup] Instances key: ", instance_key) end

    local res, err = consul:list_keys(instance_key)
    if not res then
        return nil, err
    end

    if res.status == 404 then
        if DEBUG then ngx_log(ngx_DEBUG, "[zedcup] Instance key is 404") end
        return {}
    end

    if res.status ~= 200 then
        return nil, err
    end

    --if DEBUG then ngx_log(ngx_DEBUG, "[zedcup] Instance list response: \n", require("cjson").encode(res.body)) end

    local list, tmp = {}, {}
    local magic_len = #instance_key + 1

    for _, k in ipairs(res.body) do
        k = str_sub(k, magic_len)

        local pos = str_find(k, "/", 1, true)

        if pos then
            local id = str_sub(k, 1, pos-1)
            tmp[id] = true
        end
    end

    local i = 0
    for id, _ in pairs(tmp) do
        i = i +1
        list[id] = true -- lookup entry
        list[i] = id    -- iterable entry
    end


    if DEBUG then ngx_log(ngx_DEBUG, "[zedcup] Found instances: \n", require("cjson").encode(list)) end

    return list
end
_M._instance_list = _instance_list


local function instance_list()
    local list, err, hit_level = GLOBALS.cache:get("instance_list", nil, _instance_list)
    if err then
        ngx_log(ngx_ERR, "[zedcup] Failed to get Instance list: ", err)
        return {}, err
    end

    if DEBUG then ngx_log(ngx_DEBUG, "[zedcup] Instance list hit level: ", hit_level) end

    return list
end
_M.instance_list = instance_list


local function bind(event, func)
    if not events[event] then
        return nil, "Event not found"
    end

    if type(func) ~= "function" then
        return nil, "Can only bind a function"
    end

    local listeners = GLOBALS.listeners[event]
    if not listeners then
        GLOBALS.listeners[event] = {}
        listeners = GLOBALS.listeners[event]
    end

    tbl_insert(listeners, func)

    return true
end
_M.bind = bind


local function emit(event, instance, data)
    if DEBUG then ngx_log(ngx_DEBUG, "[zedcup] Emitting: ", event) end

    local listeners = GLOBALS.listeners[event]

    if listeners then
        for _, func in ipairs(listeners) do
            local ok, err = pcall(func, instance, data)
            if not ok then
                ngx_log(ngx_ERR, "[zedcup] Error running global listener, event '", event,"': ", err)
            end
        end
    end

end
_M._emit = emit


function _M.create_handler(instance)
    if not instance or type("instance") ~= "string" then
        return nil, "Bad instance ID"
    end

    if not instance_list()[instance] then
        return nil, "Instance not found"
    end

    if not GLOBALS["op_data"][instance] then
        GLOBALS["op_data"][instance] = {}
    end

    -- Create short-lived handler instance
    return require("zedcup.handler").new(instance)
end


return _M
