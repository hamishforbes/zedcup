local ngx_log = ngx.log
local ngx_DEBUG = ngx.DEBUG
local tbl_insert = table.insert
local str_find = string.find
local str_sub = string.sub

local resty_consul = require("resty.consul")

local _M = {
    _VERSION = "0.0.1",

}


local function tbl_copy(orig)
    local orig_type = type(orig)
    local copy
    if orig_type == "table" then
        copy = {}
        for orig_key, orig_value in next, orig, nil do
            copy[tbl_copy(orig_key)] = tbl_copy(orig_value)
        end
    else -- number, string, boolean, etc
        copy = orig
    end
    return copy
end
_M.tbl_copy = tbl_copy -- Allow access from sub-modules


local function tbl_copy_merge_defaults(t1, defaults)
    if t1 == nil then t1 = {} end
    if defaults == nil then defaults = {} end
    if type(t1) == "table" and type(defaults) == "table" then
        local copy = {}
        for t1_key, t1_value in next, t1, nil do
            copy[tbl_copy(t1_key)] = tbl_copy_merge_defaults(
                t1_value, tbl_copy(defaults[t1_key])
            )
        end
        for defaults_key, defaults_value in next, defaults, nil do
            if t1[defaults_key] == nil then
                copy[tbl_copy(defaults_key)] = tbl_copy(defaults_value)
            end
        end
        return copy
    else
        return t1 -- not a table
    end
end
_M.tbl_copy_merge_defaults = tbl_copy_merge_defaults


local function str_split(str, delim)
    local pos, endpos, prev, i = 0, 0, 0, 0 -- luacheck: ignore pos endpos
    local out = {}
    repeat
        pos, endpos = str_find(str, delim, prev, true)
        i = i+1
        if pos then
            out[i] = str_sub(str, prev, pos-1)
        else
            if prev <= #str then
                out[i] = str_sub(str, prev, -1)
            end
            break
        end
        prev = endpos +1
    until pos == nil

    return out
end
_M.str_split = str_split


local function entries2table(entries, prefix, cb)
    local DEBUG = require("zedcup").globals().DEBUG

    -- Parse response
    local res = {}
    local magic_len = #(prefix or "")+1

    if DEBUG then ngx_log(ngx_DEBUG, "[zedcup] Prefix: ", prefix) end

    for _, entry in pairs(entries) do
        local val = entry["Value"]

        -- Split key on /
        local key = str_split(str_sub(entry["Key"], magic_len), "/")

        if DEBUG then ngx_log(ngx_DEBUG, "[zedcup] Parsing key: ", entry["Key"]) end
        -- Iterate over the key parts
        -- Create sub-tables and set values
        local start = res
        local last = #key
        for idx, part in ipairs(key) do
            -- Convert to numbers if possible
            part = tonumber(part) or part
            val = tonumber(val)   or val

            -- Convert booleans
            if val == "true" then
                val = true
            elseif val == "false" then
                val = false
            end

            if type(start) ~= "table" then
                return nil, "Could not parse config from Consul"

            -- Last component of the key, set the value
            elseif idx == last then
                -- If a callback is specified use it to set the actual value
                -- Otherwise set to the entry Value
                if cb then
                    cb(start, part, entry)
                else
                    start[part] = val
                end

            elseif not start[part] then
                if DEBUG then ngx_log(ngx_DEBUG, "[zedcup] Creating table for ", part) end
                start[part] = {}

            end

            start = start[part]
        end

    end

    return res
end
_M.entries2table = entries2table


local function table2txn(prefix, data, txn)
    local DEBUG = require("zedcup").globals().DEBUG

    for k, v in pairs(data) do
        if DEBUG then ngx_log(ngx_DEBUG, "[zedcup] ", prefix, " ", k, " ", type(v)) end

        -- The actual consul key
        local key = prefix..k

        if type(v) == "table" then
            -- Recurse into the table
            table2txn(key.."/", v, txn)

        else
            -- Not a table, add the value to the transaction
            tbl_insert(txn, {
                KV = {
                    Verb   = "set",
                    Key    = key,
                    Value  = v,
                }
            })

        end

    end
end
_M.table2txn = table2txn


local function error_delay(attempt)
    local delay = 2^attempt
    if delay > 300 then
        delay = 300
    end
    return delay
end
_M.error_delay = error_delay


local function thread_map(map, func, ...)
    local spawn      = ngx.thread.spawn
    local wait       = ngx.thread.wait
    local threads    = {}
    local thread_idx = 0
    local thread_res = {}

    -- Spawn a thread for each entry in the map
    for _, m in ipairs(map) do
        thread_idx = thread_idx + 1
        threads[thread_idx] = spawn(func, m, ...)
    end

    -- Wait for threads to return
    for i = 1, thread_idx do
        local _, res = wait(threads[i])
        thread_res[i] = res
    end

    return thread_res
end
_M.thread_map = thread_map


local function consul_client()
    local globals = require("zedcup").globals()
    if not globals then
        return nil, "No globals"
    end

    local config = globals.consul_config
    if not config then
        return nil, "No consul config"
    end

    return resty_consul:new(config)
end
_M.consul_client = consul_client


local function array2hash(arr)
    if not arr or not type(arr) == "table" then
        return
    end

    local hash = {}

    for _, v in ipairs(arr) do
        hash[v] = true
    end

    return hash
end
_M.array2hash = array2hash


return _M
