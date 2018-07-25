# vim:set ft= ts=4 sw=4 et:
use Test::Nginx::Socket 'no_plan';
use Cwd qw(cwd);

my $pwd = cwd();

$ENV{TEST_CONSUL_HOST}   ||= "127.0.0.1";
$ENV{TEST_CONSUL_PORT}   ||= "8500";
$ENV{TEST_NGINX_PORT}    ||= 1984;
$ENV{TEST_ZEDCUP_PREFIX} ||= "zedcup_test_suite";

no_diff();
no_long_string();

our $HttpConfig = qq{
    lua_package_path "$pwd/lib/?.lua;;";
    error_log logs/error.log debug;

    lua_shared_dict zedcup_cache 1m;
    lua_shared_dict zedcup_locks 1m;
    lua_shared_dict zedcup_ipc 1m;

    init_by_lua_block {
        require("resty.core")

        local zedcup = require("zedcup")
        zedcup._debug(true)

        TEST_CONSUL_PORT = $ENV{TEST_CONSUL_PORT}
        TEST_CONSUL_HOST = "$ENV{TEST_CONSUL_HOST}"
        TEST_NGINX_PORT  = $ENV{TEST_NGINX_PORT}
        TEST_ZEDCUP_PREFIX = "$ENV{TEST_ZEDCUP_PREFIX}"

        zedcup.init({
            consul = {
                host = TEST_CONSUL_HOST,
                port = TEST_CONSUL_PORT,
            },
            prefix = TEST_ZEDCUP_PREFIX
        })

        DEFAULT_CONF = {

            http = true,

            pools = {
                {
                    name = "primary",
                    timeout = 100,
                    status_codes = {"50x"},
                    hosts = {
                        { name = "web01", host = "127.0.0.1", port = TEST_NGINX_PORT },
                        { name = "web02", host = "127.0.0.1", port = TEST_NGINX_PORT }
                    }
                },
                {
                    hosts = {
                    {  name = "dr01", host = "127.0.0.1", port = TEST_NGINX_PORT}

                    }
                },
                {
                    name = "tertiary",
                    healthcheck = true,
                    hosts = {
                        { host = "127.0.0.1", port = TEST_NGINX_PORT+1,
                            healthcheck = {
                                path = "/_health",
                                status_codes = {"5xx", "3xx"},
                            }
                        }

                    }
                },
            },
        }

    }

};

run_tests();

__DATA__
=== TEST 1: config
--- http_config eval: $::HttpConfig
--- config
    location = /a {
        content_by_lua_block {
            local zedcup = require("zedcup")
            local globals = zedcup.globals()

            local c = require("resty.consul"):new({
                host = TEST_CONSUL_HOST,
                port = TEST_CONSUL_port,
            })

            -- Clear up before running test
            c:delete_key(globals.prefix, {recurse = true})

            -- Configure the instance
            local ok, err = zedcup.configure_instance("test", DEFAULT_CONF)
            if not ok then ngx.say(err) end

            local handler, err = zedcup.create_handler("test")
            if err then error(err) end

            local config, err = handler:config()
            ngx.log(ngx.DEBUG, require("cjson").encode(config))
            if err then error(err) end

            ngx.say(config.http)
            ngx.say(config.pools[1].name)
            ngx.say(config.pools[1].hosts[1].name)

            -- Defaults applied
            ngx.say(config.pools[1].method)
            ngx.say(config.pools[1].hosts[1].up)
            ngx.say(config.pools[3].healthcheck.path)
            ngx.say(config.pools[3].hosts[1].healthcheck.path)

            ngx.say(config.pools[2].name)
            ngx.say(config.pools[3].hosts[1].name)

            -- status_codes converted to hash
            ngx.say(config.pools[1].status_codes["50x"])
            ngx.say(config.pools[3].hosts[1].healthcheck.status_codes["3xx"])

            -- config is immutable
            config["foo"] = "bar"
            config.pools[1]["hosts"] = nil

            local config, err = handler:config()
            ngx.log(ngx.DEBUG, require("cjson").encode(config))
            if err then error(err) end

            ngx.say(config.foo)
            ngx.say(config.pools[1].hosts[1].name)

        }
    }
--- request
GET /a
--- response_body
true
primary
web01
weighted_rr
true
/
/_health
2
1
true
true
nil
web01
--- no_error_log
[error]
[warn]

=== TEST 2: connect
--- http_config eval: $::HttpConfig
--- config
    location = /a {
        content_by_lua_block {
            local zedcup = require("zedcup")
            local globals = zedcup.globals()

            local c = require("resty.consul"):new({
                host = TEST_CONSUL_HOST,
                port = TEST_CONSUL_port,
            })

            -- Clear up before running test
            c:delete_key(globals.prefix, {recurse = true})


            -- Configure the instance
            local ok, err = zedcup.configure_instance("test", DEFAULT_CONF)
            if not ok then ngx.say(err) end

            local handler, err = zedcup.create_handler("test")
            if err then error(err) end

            local connected
            handler:bind("host_connect", function(data)
                connected = data
            end)

            local sock, err = handler:connect()
            if err then error(err) end

            if sock then
                ngx.say(connected.pool.name, "/", connected.host.name )
                ngx.say("ctx: ", handler.ctx.connected_host._pool.name, "/", handler.ctx.connected_host.name )
            else
                ngx.say("fail")
            end

        }
    }
--- request
GET /a
--- response_body
primary/web01
ctx: primary/web01
--- no_error_log
[error]
[warn]

=== TEST 3: connect, bad hosts
--- http_config eval: $::HttpConfig
--- config
    location = /a {
        content_by_lua_block {
            local zedcup = require("zedcup")
            local globals = zedcup.globals()

            local c = require("resty.consul"):new({
                host = TEST_CONSUL_HOST,
                port = TEST_CONSUL_port,
            })

            -- Clear up before running test
            c:delete_key(globals.prefix, {recurse = true})

            -- Host 1 is down
            local tbl_copy = require("zedcup.utils").tbl_copy
            local conf = tbl_copy(DEFAULT_CONF)

            conf.pools[1].hosts[1].up = false

            -- Configure the instance
            local ok, err = zedcup.configure_instance("test", conf)
            if not ok then ngx.say(err) end

            local handler, err = zedcup.create_handler("test")
            if err then error(err) end


            local connected
            handler:bind("host_connect", function(data)
                connected = data
            end)

            local errors = {}
            handler:bind("host_error", function(data)
                table.insert(errors, data)
            end)

            local sock, err = handler:connect()
            if err then error(err) end

            if sock then
                ngx.say(connected.host._pool.name, "/", connected.host.name )
            else
                ngx.say("nil")
            end

        }
    }
--- request
GET /a
--- response_body
primary/web02
--- no_error_log
[error]
[warn]


=== TEST 4: events
--- http_config eval: $::HttpConfig
--- config
    location = /a {
        content_by_lua_block {
            local zedcup = require("zedcup")
            local globals = zedcup.globals()

            local c = require("resty.consul"):new({
                host = TEST_CONSUL_HOST,
                port = TEST_CONSUL_port,
            })

            -- Clear up before running test
            c:delete_key(globals.prefix, {recurse = true})

            -- Configure the instance
            local ok, err = zedcup.configure_instance("test", DEFAULT_CONF)
            if not ok then ngx.say(err) end

            local handler, err = zedcup.create_handler("test")
            if err then error(err) end



            local cb_res

            -- Bind invalid event
            local ok, err = handler:bind("invalid event", function(data)
                cb_res = true
            end)
            ngx.log(ngx.DEBUG, "OK: ", ok, " err: ", err, " cb_res: ", cb_res)
            assert(ok == nil and err ~= nil and cb_res == nil, "Bound invalid event")

            -- Bind invalid cb
            local ok, err = handler:bind("invalid event", "test")
            ngx.log(ngx.DEBUG, "OK: ", ok, " err: ", err, " cb_res: ", cb_res)
            assert(ok == nil and err ~= nil, "Bound string cb...")


            -- Valid bind
            local ok, err = handler:bind("host_connect", function(data)
                ngx.log(ngx.DEBUG, "callback got: ", data)
                cb_res = data
            end)
            ngx.log(ngx.DEBUG, "OK: ", ok, " err: ", err, " cb_res: ", cb_res)
            assert(ok == true and err == nil, "Could not bind host_connect")

            -- Emit the event and check cb was run
            handler:_emit("host_connect", "foobar")
            assert(cb_res == "foobar", "Callback mismatch")

            cb_res = nil

            -- callbacks are pcall'd
            local cb_res2

            local ok, err = handler:bind("host_connect", function(data)
                ngx.log(ngx.DEBUG, "callback2 got: ", data)
                cb_res2 = data

                local error = 1234 + data -- string + number, throws error

            end)
            ngx.log(ngx.DEBUG, "OK: ", ok, " err: ", err, " cb_res: ", cb_res)
            assert(ok == true and err == nil, "Could not bind host_connect")

            -- Emit the event and check both cbw were run, errors caught
            handler:_emit("host_connect", "foobar2")
            assert(cb_res == "foobar2", "Callback mismatch")
            assert(cb_res2 == "foobar2", "Callback2 mismatch")

            cb_res = nil
            cb_res2 = nil


            -- Bind a different event
            local cb_res3
            local ok, err = handler:bind("host_down", function(data)
                ngx.log(ngx.DEBUG, "callback got: ", data)
                cb_res3 = data
            end)
            ngx.log(ngx.DEBUG, "OK: ", ok, " err: ", err, " cb_res: ", cb_res)
            assert(ok == true and err == nil, "Could not bind host_down")

            -- Emit the event and check cb was run
            handler:_emit("host_down", "foobar")
            assert(cb_res3 == "foobar", "Callback3 mismatch")

            cb_res3 = nil


            -- CB are run in order
            -- Bind another event
            local ok, err = handler:bind("host_down", function(data)
                ngx.log(ngx.DEBUG, "callback got: ", data)
                cb_res3 = "override"
            end)
            ngx.log(ngx.DEBUG, "OK: ", ok, " err: ", err, " cb_res: ", cb_res)
            assert(ok == true and err == nil, "Could not bind host_down")

            -- Emit the event and check cb was run
            handler:_emit("host_down", "foobar")
            assert(cb_res3 == "override", "Callback override mismatch")

            cb_res3 = nil


            local gb_res

            -- Global bind
            local ok, err = zedcup.bind("host_connect", function(instance, data)
                ngx.log(ngx.DEBUG, "global callback got instance ", instance, ": ", data)
                gb_res = data
            end)
            ngx.log(ngx.DEBUG, "OK: ", ok, " err: ", err, " cb_res: ", cb_res)
            assert(ok == true and err == nil, "Could not glboal bind host_connect")

            -- Emit the event and check global cb was run
            handler:_emit("host_connect", "foobar")
            assert(gb_res == "foobar", "Global Callback mismatch")

            gb_res = nil


            ngx.say("OK")
        }
    }
--- request
GET /a
--- response_body
OK
--- error_log
[zedcup (test)] Error running listener

=== TEST 5: connect, failing hosts
--- http_config eval: $::HttpConfig
--- config
    location = /a {
        content_by_lua_block {
            local zedcup = require("zedcup")
            local globals = zedcup.globals()

            local c = require("resty.consul"):new({
                host = TEST_CONSUL_HOST,
                port = TEST_CONSUL_port,
            })

            -- Clear up before running test
            c:delete_key(globals.prefix, {recurse = true})

            -- Host 1 is down
            local tbl_copy = require("zedcup.utils").tbl_copy
            local conf = tbl_copy(DEFAULT_CONF)

            conf.pools[1].hosts[1].port = TEST_NGINX_PORT + 1

            -- Configure the instance
            local ok, err = zedcup.configure_instance("test", conf)
            if not ok then ngx.say(err) end

            local handler, err = zedcup.create_handler("test")
            if err then error(err) end


            local connected
            handler:bind("host_connect", function(data)
                connected = data
            end)

            local errors = {}
            handler:bind("host_connect_error", function(data)
                table.insert(errors, data)
            end)

            local sock, err = handler:connect()
            if err then error(err) end

            if sock then

                ngx.say(connected.pool.name, "/", connected.host.name )

                for _,err in ipairs(errors) do
                    ngx.say(err.pool.name, "/", err.host.name, ": ", err.err)
                end

            else
                ngx.say("nil")
            end

        }
    }
--- request
GET /a
--- response_body
primary/web02
primary/web01: connection refused


=== TEST 6: state
--- http_config eval: $::HttpConfig
--- config
    location = /a {
        content_by_lua_block {
            local zedcup = require("zedcup")
            local globals = zedcup.globals()

            local c = require("resty.consul"):new({
                host = TEST_CONSUL_HOST,
                port = TEST_CONSUL_port,
            })

            -- Clear up before running test
            c:delete_key(globals.prefix, {recurse = true})

            -- Configure the instance
            local ok, err = zedcup.configure_instance("test", DEFAULT_CONF)
            if not ok then ngx.say(err) end

            local handler, err = zedcup.create_handler("test")
            if err then error(err) end

            local config = handler:config()

            -- No state
            local state, err = handler:state()
            if err then error(err) end
            if state then error("shouldn't have state yet") end

            -- Error with no host provided
            local error_count, err = handler:incr_host_error_count()
            assert(error_count == nil, err ~= nil, "No host")

            -- Increment host
            local error_count, err = handler:incr_host_error_count(config.pools[1].hosts[1])
            if err then error("incr: ", err) end
            ngx.say("count: ", error_count)

            local error_count, err = handler:incr_host_error_count(config.pools[1].hosts[1])
            if err then error("incr2: ", err) end
            ngx.say("count: ", error_count)

            -- Inject state
            c:put_key(globals.prefix.."/state/test/1/2/error_count", 999, {flags = 123456} )


            -- Last check
            local ok, err = handler:set_host_last_check(config.pools[2].hosts[1])
            if err then error("lastcheck: ", err) end

            -- check
            local state, err = handler:state()
            if err then error(err) end
            ngx.say("state: ", state[1][1].error_count, " ", type(state[1][1].last_error))
            ngx.say("last_check: ",type(state[2][1].last_check))
            ngx.say("state: ", state[1][2].error_count, " ", state[1][2].last_error)


            -- reset
            local ok, err = handler:reset_host_error_count(config.pools[1].hosts[2])
            if err then error("reset: ", err) end
            ngx.say("reset: ", ok)

            -- Reset host with no state
            local ok, err = handler:reset_host_error_count(config.pools[2].hosts[1])
            if err then error("reset2: ", err) end
            ngx.say("reset2: ", ok)

            local state, err = handler:state()
            if err then error(err) end
            ngx.say("state: ", state[1][1].error_count, " ", type(state[1][1].last_error))
            ngx.say("state: ", state[1][2])


        }
    }
--- request
GET /a
--- response_body
count: 1
count: 2
state: 2 number
last_check: number
state: 999 123456
reset: true
reset2: true
state: 2 number
state: nil
--- no_error_log
[error]
[warn]


=== TEST 7: host status
--- http_config eval: $::HttpConfig
--- config
    location = /a {
        content_by_lua_block {
            local zedcup = require("zedcup")
            local globals = zedcup.globals()

            local c = require("resty.consul"):new({
                host = TEST_CONSUL_HOST,
                port = TEST_CONSUL_port,
            })

            -- Clear up before running test
            c:delete_key(globals.prefix, {recurse = true})

            -- Configure the instance
            local ok, err = zedcup.configure_instance("test", DEFAULT_CONF)
            if not ok then ngx.say(err) end

            local handler, err = zedcup.create_handler("test")
            if err then error(err) end

            local config, err = handler:config()
            if err then error(err) end

            -- Error with no host provided
            local ok, err = handler:set_host_down()
            assert(ok == nil, err ~= nil, "No host")
            local ok, err = handler:set_host_up()
            assert(ok == nil, err ~= nil, "No host")

            -- Set down host
            local ok, err = handler:set_host_down(config.pools[1].hosts[1])
            if err then error("down: ".. err) end
            ngx.say("down: ", ok)

            local ok, err = handler:set_host_down(config.pools[3].hosts[1])
            if err then error("down2: ".. err) end
            ngx.say("down2: ", ok)

            globals.cache:purge()

            -- check config
            local config, err = handler:config()
            if err then error(err) end

            ngx.say(config.pools[1].hosts[1].up)
            ngx.say(config.pools[3].hosts[1].up)


            -- up again
            local ok, err = handler:set_host_up(config.pools[1].hosts[1])
            if err then error("up: ".. err) end
            ngx.say("up: ", ok)

            local ok, err = handler:set_host_up(config.pools[3].hosts[1])
            if err then error("up2: ".. err) end
            ngx.say("up2: ", ok)


            globals.cache:purge()

            -- check config
            local config, err = handler:config()
            if err then error(err) end

            ngx.say(config.pools[1].hosts[1].up)
            ngx.say(config.pools[3].hosts[1].up)


        }
    }
--- request
GET /a
--- response_body
down: true
down2: true
false
false
up: true
up2: true
true
true
--- no_error_log
[error]
[warn]


=== TEST 8: http request
--- http_config eval: $::HttpConfig
--- config
    location = /a {
        content_by_lua_block {
            local zedcup = require("zedcup")
            local globals = zedcup.globals()

            local c = require("resty.consul"):new({
                host = TEST_CONSUL_HOST,
                port = TEST_CONSUL_port,
            })

            -- Clear up before running test
            c:delete_key(globals.prefix, {recurse = true})

            -- Configure the instance
            local ok, err = zedcup.configure_instance("test", DEFAULT_CONF)
            if not ok then ngx.say(err) end

            local handler, err = zedcup.create_handler("test")
            if err then error(err) end

            local res, err = handler:request({
                path = "/b",
            })
            if err then error(err) end

            ngx.say(res.status)
            ngx.print(res:read_body())

        }

    }

    location = /b {
        echo "OK";
    }

--- request
GET /a
--- response_body
200
OK
--- no_error_log
[error]
[warn]

=== TEST 9: ctx
--- http_config eval: $::HttpConfig
--- config
    location = /a {
        content_by_lua_block {
            local zedcup = require("zedcup")
            local globals = zedcup.globals()

            local c = require("resty.consul"):new({
                host = TEST_CONSUL_HOST,
                port = TEST_CONSUL_port,
            })

            -- Clear up before running test
            c:delete_key(globals.prefix, {recurse = true})

            -- Configure the instances
            local ok, err = zedcup.configure_instance("test", DEFAULT_CONF)
            if not ok then ngx.say(err) end
            local ok, err = zedcup.configure_instance("test2", DEFAULT_CONF)
            if not ok then ngx.say(err) end

            local handler, err = zedcup.create_handler("test")
            if err then error(err) end
            local handler2, err = zedcup.create_handler("test2")
            if err then error(err) end

            handler.ctx.foo = "test1"
            ngx.say("ctx1.foo: ", handler.ctx.foo)
            ngx.say("ctx2.foo: ", handler2.ctx.foo)
            ngx.say()

            handler2.ctx.foo = "test2"
            ngx.say("ctx1.foo: ", handler.ctx.foo)
            ngx.say("ctx2.foo: ", handler2.ctx.foo)
            ngx.say()

            -- Recreate handlers, should not override
            local handlerB, err = zedcup.create_handler("test")
            if err then error(err) end
            local handler2B, err = zedcup.create_handler("test2")
            if err then error(err) end

            ngx.say("ctx1.foo: ", handler.ctx.foo)
            ngx.say("ctx2.foo: ", handler2.ctx.foo)
            ngx.say("ctx1B.foo: ", handlerB.ctx.foo)
            ngx.say("ctx2B.foo: ", handler2B.ctx.foo)
            ngx.say()

            handlerB.ctx.foo = "test1B"
            handler2B.ctx.foo = "test2B"

            ngx.say("ctx1.foo: ", handler.ctx.foo)
            ngx.say("ctx2.foo: ", handler2.ctx.foo)
            ngx.say("ctx1B.foo: ", handlerB.ctx.foo)
            ngx.say("ctx2B.foo: ", handler2B.ctx.foo)

        }
    }
--- request
GET /a
--- response_body
ctx1.foo: test1
ctx2.foo: nil

ctx1.foo: test1
ctx2.foo: test2

ctx1.foo: test1
ctx2.foo: test2
ctx1B.foo: test1
ctx2B.foo: test2

ctx1.foo: test1B
ctx2.foo: test2B
ctx1B.foo: test1B
ctx2B.foo: test2B
--- no_error_log
[error]
[warn]
