# zedcup

Zero Conf Upstream load balancing and failover for Openresty and Consul

[![Build Status](https://travis-ci.com/hamishforbes/zedcup.svg?branch=master)](https://travis-ci.com/hamishforbes/zedcup)

# Table of Contents

* [Status](#status)
* [Overview](#overview)
* [Configuration](#configuration)
* [API](#api)
    * [zedcup](#zedcup)
    * [handler](#handler)
* [Events](#events)


# Status

Experimental, API may change without warning.

# Overview

```lua
http {
    lua_package_path "/PATH/TO/zedcup/lib/?.lua;;";

    lua_shared_dict zedcup_cache 1m;
    lua_shared_dict zedcup_locks 1m;
    lua_shared_dict zedcup_ipc 1m;
    lua_socket_log_errors off;

    init_by_lua_block {
        require "resty.core"

        require("zedcup").init({
            consul = {
                host = "127.0.0.1",
                port = 8500,
            },
        })
    }

    init_worker_by_lua_block {
        require("zedcup").run_workers()
    }

    server {
        listen 80;

        server_name zedcup;

        location /_configure {
            content_by_lua_block {
                local conf = {
                    pools = {
                        {
                            name = "primary",
                            timeout = 100,
                            healthcheck = {
                                path = "/_health"
                            },
                            hosts = {
                                { name = "web01", host = "10.10.10.1", port = 80 },
                                { name = "web02", host = "10.10.10.2", port = 80 }
                            }
                        },
                        {
                            name = "secondary",
                            hosts = {
                                {
                                    name = "dr01", host = "10.20.20.1", weight = 10, port = "80",
                                    healthcheck = {
                                        path = "/dr_check",
                                        headers = {
                                            ["Host"] = "www.example.com"
                                        }
                                    },
                                }
                            }
                        },
                    }
                }

                local ok, err = require("zedcup").configure_instance("test", conf)
                if not ok then error(err) end
            }
        }

        location / {
            content_by_lua_block {
                local handler, err = require("zedcup").create_handler("test")
                assert(handler, err)

                local res, err = handler:request({ path = "/test" })
                assert(res, err)

                ngx.say(res.status)
                ngx.say(res:read_body())

                handler:set_keepalive()

            }
        }
    }

}
```

## Dependencies
  * pintsized/lua-resty-http
  * thibaultcha/lua-resty-mlcache
  * hamishforbes/lua-resty-consul

# Configuration

All configuration beyond the bare minimum required to connect to Consul, is stored in the Consul KV store.

Configs can be saved to Consul with the [configure](#configure) and [configure_instance](#configure_instance) methods.


### Global configuration

Consul keys: `<prefix>/config/<key>`

Defaults

```lua
{
    host_revive_interval   = 10,
    cache_update_interval  = 1,
    healthcheck_interval   = 10,
    watcher_interval       = 10,
    session_renew_interval = 10,
    session_ttl            = 30,
    worker_lock_ttl        = 30,
    consul_wait_time       = 600,
}
```

```
consul kv put zedcup/config/consul_wait_time 300
```

### Instance configuration

Consul keys: `<prefix>/instances/<instance>/<key>/<sub-key>`

Defaults

```lua
{
    ssl         = false,
    healthcheck = nil
}

```

```
consul kv put zedcup/instances/my_instance/healthcheck/path /_healtcheck
```

#### SSL configuration

```lua
instance.ssl = {
    ssl_verify = true,
    sni_name   = "sni.domain.tld
}
```

### Pool configuration

Consul keys: `<prefix>/instances/<instance>/pools/<index>/<key>`

Defaults
```lua
{
    name          = index -- If name is not set the index number will be used
    up            = true, -- Set to false to never try hosts in this pool
    method        = "weighted_rr",
    timeout       = 2000, -- (ms) socket connect timeout
    error_timeout = 60,   -- (s) down hosts will be revived after this long without an error
    max_errors    = 3,    -- Number of failures within error_timeout before a host is marked down

    -- HTTP options
    read_timeout      = 10000, -- (ms) Timeout set after successful connection
    keepalive_timeout = 60000, -- (ms)
    keepalive_pool    = 128,   -- (ms)
    status_codes      = { "5xx", "4xx" } -- Table of status codes which indicate a request failure
    healthcheck       = nil
}
```

```
consul kv put zedcup/instances/my_instance/pools/1/name my_pool_name
```

### Host configuration

Consul keys: `<prefix>/instances/<instance>/pools/<index>/hosts/<index>/<key>`

Defaults
```lua
{
    name        = index -- If name is not set the index number will be used
    host        = nil,  -- Required, hostname, IP or unix socket path
    port        = nil,  -- Required unless host is a unix socket
    up          = true, -- Set to false to mark this host as failed
    weight      = 1,
    healthcheck = nil
}
```

```
consul kv put zedcup/instances/my_instance/pools/1/hosts/1/port 8080
```

### Healthcheck configuration

HTTP healthchecks can be configured at the instance, pool or host level.  
Setting the healthcheck param at any of these levels to `true` will use the defaults.

Healthchecks are only performed from 1 node in the cluster at a time.

Defaults
```lua
{
    ssl        = nil,   -- Override instance SSL configuration
    interval   = 60,    -- Frequency of checks
    method     = "GET", -- HTTP requset method
    path       = "/",   -- HTTP URI path
    headers = {         -- Table of headers to send
        ["User-Agent"] = "zedcup/".. _M._VERSION.. " HTTP Check (lua)"
    },
    status_codes = { "5xx", "4xx" } -- Status codes which indicate a failure, this default is only used if the pool has no status codes configured
}
```

```
consul kv put zedcup/instances/my_instance/healthcheck/headers/Host www.real-domain.tld
```

# API

## Zedcup

 * [init](#init)
 * [initted](#initted)
 * [run_workers](#run_workers)
 * [config](#config)
 * [configure](#configure)
 * [configure_instance](#configure_instance)
 * [remove_instance](#remove_instance)
 * [instance_list](#instance_list)
 * [bind](#bind)
 * [create_handler](#create_handler)

### init

`syntax: ok = zedcup.init(opts?)`

Initialise zedcup with enough configuration to access consul and retrieve the rest of the configuration.

`opts` is an optional table which will be merged with the defaults:   

```lua
{
    prefix = "zedcup", -- Consul KV store prefix to use
    consul = {},       -- Consul connection settings, see lua-resty-consul for defaults
    dicts  = {         -- The 3 required shared dictionaries
        cache = "zedcup_cache",
        locks = "zedcup_locks",
        ipc   = "zedcup_ipc",
    }
}
```

### initted

`syntax: ok = zedcup.initted()`

Returns `true` if `zedcup.init()` has already been called, otherwise `false`

### run_workers

`syntax: zedcup.run_workers()`

Start all the required workers, returns `nil`

### config

`syntax: config, err = zedcup.config()`

Get the global zedcup configuration from consul.

Returns `nil` and an error on failure.

### configure

`syntax: ok, err = zedcup.configure(config)`

Set the global zedcup configuration (as a table) in consul.

Will overwrite any existing configuration.

Returns `nil` and an error on failure.

### configure_instance

`syntax: ok, err = zedcup.configure_instance(instance, config)`

Set or create the configuration for the named `instance`.

Will clear any existing configuration and state for the instance.

Returns `nil` and an error on failure.

### remove_instance

`syntax: ok, err = zedcup.remove_instance(instance)`

Delete configuration and state for the named `instance`.

Returns `nil` and an error on failure.

### instance_list

`syntax: list, err = zedcup.instance_list()`

Get a list of zedcup instances from consul.

The list is a mixed associative/numeric table that is both iterable with `ipairs` and has a named key for each instance.

```lua
local list, err = require("zedcup").instance_list()
if err then
    ngx.log(ngx.ERR, err)
    return
end

if list["my_instance"] then
    ngx.say("Instance exists")
end

for _, instance in ipairs(list) do
    ngx.say("Instance name: ", instance)
end
```

Returns `nil` and an error on failure.

### bind

`syntax: ok, err = zedcup.bind(event, callback)`

Globally bind a callback function to a particularly [events](#events).

Callbacks bound globally will receive 2 arguments,  
the first is the instance name and the second the event data.

```lua
local ok, err = require("zedcup").bind("host_connect_error", function(instance, data)
    if instance == "instance_i_care_about" then
        ngx.say("Error connecting to host: '", data.host.name, "': ", data.err)
    end
end)

```

Callbacks are executed in the order they were bound.

Returns `nil` and an error on failure.

### create_handler

`syntax: handler, err = zedcup.create_handler(instance)`

Returns a short lived [handler](#handler) object for the given instance.

Handler objects are not intended to live beyond the lifetime of a request.

```lua
local handler, err = zedcup.create_handler("my_instance_name")
if err then return nil, err end

local sock, err = handler:connect()

```

Returns `nil` and an error on failure.

## Handler

 * [bind](#bind)
 * [config](#config)
 * [connect](#connect)
 * [request](#request)
 * [get_client_body_reader](#get_client_body_reader)
 * [set_keepalive](#set_keepalive)
 * [get_reused_times](#get_reused_times)
 * [close](#close)

### bind

`syntax: ok, err = handler:bind(event, callback)`

Bind a callback function to a particularly [events](#events) for the lifetime of the handler only.

```lua
local ok, err = handler:bind("host_connect_error", function(data)
    ngx.say("Error connecting to host: '", data.host.name, "': ", data.err)
end)

```

Callbacks are executed in the order they were bound and before global callbacks.

Returns `nil` and an error on failure.

### config

`syntax: config, err = handler:config()`

Get the instance configuration from consul.

Returns `nil` and an error on failure.

### connect

`syntax: sock, err = handler:connect(sock?)`

Returns a connected [ngx.socket.tcp](openresty/lua-nginx-module#ngxsockettcp) socket.

If the `sock` paramater is not provided a new socket is object is created and returned.   
The `sock` parameter can also be a lua-resty client driver, as long as it supports the `connect` and `set_timeout` methods.

If the zedcup instance is configured for SSL then the ssl handshake will already have been performed.

This allows load balancing and failover of client drivers such as [lua-resty-redis](https://github.com/openresty/lua-resty-redis)

```lua
local handler, err = zedcup.create_handler("my_instance_name")
if err then return nil, err end

local sock, err = handler:connect()

sock:send("data")

local redis = require("resty.redis").new()

redis, err = handler:connect(redis)

redis:get("foo")

```

Returns `nil` and an error on failure.

### request

`syntax: res, err = handler:request(params)`

Convenience method for making an HTTP request to the configured upstream host.

A handler object can be used in place of a resty-http instance.

Takes the same arguments and returns the same values as [resty-http:requst()](https://github.com/pintsized/lua-resty-http#request)


### get_client_body_reader

Proxy method for [resty-http:get_client_body_reader()](https://github.com/pintsized/lua-resty-http#get_client_body_reader)

### set_keepalive

Proxy method for [resty-http:set_keepalive()](https://github.com/pintsized/lua-resty-http#set_keepalive)

### get_reused_times

Proxy method for [resty-http:get_reused_times()](https://github.com/pintsized/lua-resty-http#get_reused_times)

### close

Proxy method for [resty-http:close()](https://github.com/pintsized/lua-resty-http#closed)

# Events

 * [host_connect](#host_connect)
 * [host_connect_error](#host_connect_error)
 * [host_request_error](#host_request_error)
 * [host_up](#host_up)
 * [host_down](#host_down)

## host_connect

`syntax: bind("host_connect", function(data) end)`

Fired whenever a successful connection is established to a host.

```lua
data = {
    pool = { ... pool configuration ... },
    host = { ... host configuration ... }
}
```

## host_connect_error

`syntax: handler:bind("host_connect_error", function(data) end)`

Fired when a connection to a host fails.

```lua
data = {
    pool = { ... pool configuration ... },
    host = { ... host configuration ... },
    err = "Error message"
}
```

## host_request_error
`syntax: handler:bind("host_request_error", function(data) end)`

Fired when an HTTP request to a host fails.

```lua
data = {
    pool = { ... pool configuration ... },
    host = { ... host configuration ... },
    err = "Error message"
}
```

## host_up

`syntax: zedcup.bind("host_request_error", function(instance, data) end)`

Fired when a host transitions from down to up when the error timeout expires.

```lua
data = {
    pool = { ... pool configuration ... },
    host = { ... host configuration ... },
}
```

N.B.: Callbacks for this event must be bound globally, hosts are only revived by a background worker.

## host_down

`syntax: handler:bind("host_request_error", function(data) end)`

Fired when a host transitions from up to down when max_errors is exceeded.

```lua
data = {
    pool = { ... pool configuration ... },
    host = { ... host configuration ... },
}
```
