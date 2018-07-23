local ngx_log = ngx.log
local ngx_DEBUG = ngx.DEBUG
local ngx_ERR = ngx.ERR
local ngx_INFO = ngx.INFO

local zedcup  = require("zedcup")
local GLOBALS = zedcup.globals()
local DEBUG =  GLOBALS.DEBUG

--local utils = require("zedcup.utils")

local _M = {
    _VERSION = "0.0.1",
}

local function _gcd(a,b)
    -- Tail recursive gcd function
    if b == 0 then
        return a
    else
        return _gcd(b, a % b)
    end
end


local function calc_gcd_weight(hosts)
    -- Calculate the GCD and maximum weight value from a set of hosts
    local gcd = 0
    local len = #hosts - 1
    local max_weight = 0
    local i = 1

    if len < 1 then
        return 0, 0
    end

    repeat
        local tmp = _gcd(hosts[i].weight, hosts[i+1].weight)

        if tmp > gcd then
            gcd = tmp
        end

        if hosts[i].weight > max_weight then
            max_weight = hosts[i].weight
        end

        i = i +1
    until i >= len

    if hosts[i].weight > max_weight then
        max_weight = hosts[i].weight
    end

    return gcd, max_weight
end


local function get_rr_vars(handler, pool)
    local pidx = pool._idx
    local op_data = handler.op_data

    local pool_data = op_data[pidx]
    if not pool_data then
        op_data[pidx] = { hosts = {}, rr = {idx = 0, cw = 0} }
        pool_data = op_data[pidx]
    end

    local rr_vars = pool_data.rr
    if not rr_vars then
        pool_data.rr = {idx = 0, cw = 0}
        rr_vars = pool_data.rr
    end

    rr_vars.gcd, rr_vars.max_weight = calc_gcd_weight(pool.hosts)

    return rr_vars
end


local function select_weighted_rr_host(hosts, failed_hosts, rr_vars)
    local idx = rr_vars.idx
    local cw  = rr_vars.cw
    local gcd = rr_vars.gcd
    local mw  = rr_vars.max_weight

    local hostcount = #hosts
    local failed_iters = 0

    repeat
        idx = idx +1

        if idx > hostcount then
            idx = 1
        end

        if idx == 1 then
            cw = cw - gcd
            if cw <= 0 then
                cw = mw
                if cw == 0 then
                    return nil
                end
            end
        end

        local host = hosts[idx]

        if host.weight >= cw then

            if failed_hosts[idx] == nil and host.up == true then
                rr_vars.idx, rr_vars.cw = idx, cw
                if DEBUG then ngx_log(ngx_DEBUG, "[zedcup] Selected: ", host.name) end
                return host

            else
                if DEBUG then ngx_log(ngx_DEBUG, "[zedcup] Selected host is bad: ", host.name) end
                failed_iters = failed_iters+1

            end

        end

    until failed_iters > hostcount -- Checked every host, must all be down

    if DEBUG then ngx_log(ngx_DEBUG, "[zedcup] All hosts failed") end

    return nil
end


function _M.select_host(handler, pool)
    local failed_hosts = handler.ctx.failed[pool._idx]
    local hosts = pool.hosts

    -- Don't bother trying to balance between 1 host
    if #hosts == 1 then
        if DEBUG then ngx_log(ngx_DEBUG, "[zedcup] 1 host, short circuiting") end
        local host = hosts[1]

        if host.up == false or failed_hosts[1] == true then
            -- This host is bad
            if DEBUG then ngx_log(ngx_DEBUG, "[zedcup] Single host is bad") end
            return nil
        end

        if DEBUG then ngx_log(ngx_DEBUG, "[zedcup] Selected: ", host.name) end
        return host
    end

    return select_weighted_rr_host(hosts, failed_hosts, get_rr_vars(handler, pool))
end

return _M
