# zedcup

Zero Conf Upstream load balancing and failover for Openresty and Consul

[![Build Status](https://travis-ci.com/hamishforbes/zedcup.svg?branch=master)](https://travis-ci.com/hamishforbes/zedcup)

# Table of Contents

* [Status](#status)
* [Overview](#overview)


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

                local res, err = handler:request({path = "/test" })
                assert(res, err)

                ngx.say(res.status)
                ngx.say(res:read_body())

                handler:set_keepalive()

            }
        }
    }

}
```
