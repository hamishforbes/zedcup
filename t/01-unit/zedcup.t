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
    }

};

our $AltHttpConfig = qq{
    lua_package_path "$pwd/lib/?.lua;;";
    error_log logs/error.log debug;

    lua_shared_dict zedcup_cache 1m;
    lua_shared_dict zedcup_locks 1m;
    lua_shared_dict zedcup_ipc 1m;
    lua_shared_dict zedcup_alt 1m;

    init_by_lua_block {
        require("resty.core")

        local zedcup = require("zedcup")
        zedcup._debug(true)

        TEST_CONSUL_PORT = $ENV{TEST_CONSUL_PORT}
        TEST_CONSUL_HOST = "$ENV{TEST_CONSUL_HOST}"
        TEST_NGINX_PORT  = $ENV{TEST_NGINX_PORT}
        TEST_ZEDCUP_PREFIX = "$ENV{TEST_ZEDCUP_PREFIX}"

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


            -- Defaults are applied
            local conf, err = zedcup.config()
            ngx.log(ngx.DEBUG, require("cjson").encode(conf))
            if not conf then error(err) end

            ngx.say(conf.session_renew_interval)

            -- Config is immutable
            conf["foobar"] = "1234"
            conf.session_renew_interval = "asdf"

            local conf, err = zedcup.config()
            ngx.log(ngx.DEBUG, require("cjson").encode(conf))
            if not conf then error(err) end

            ngx.say(conf.foobar)
            ngx.say(conf.session_renew_interval)


            -- Inject arbitrary config
            c:put_key(globals.prefix.."/config/test", "testval")
            globals.cache:purge()

            local conf, err = zedcup.config()
            ngx.log(ngx.DEBUG, require("cjson").encode(conf))
            if not conf then error(err) end

            ngx.say(conf.test)

            -- set config
            zedcup.configure({
                worker_lock_ttl = 20,
                foobar = "test",
                sub = {
                    value = "baz"
                }
            })
            globals.cache:purge()

            local conf, err = zedcup.config()
            ngx.log(ngx.DEBUG, require("cjson").encode(conf))
            if not conf then error(err) end

            ngx.say(conf.worker_lock_ttl)
            ngx.say(conf.session_renew_interval)
            ngx.say(conf.sub.value)

        }
    }
--- request
GET /a
--- response_body
10
nil
10
testval
20
10
baz
--- no_error_log
[error]
[warn]

=== TEST 2: instance list
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


            -- No instances
            local list, err = zedcup.instance_list()
            ngx.log(ngx.DEBUG, require("cjson").encode(conf))
            if not list then error(err) end

            local count = 0
            for id, _ in pairs(list) do
                count = count +1
            end
            ngx.say(count)

            -- Inject arbitrary data
            c:put_key(globals.prefix.."/instances/test/name", "test")
            c:put_key(globals.prefix.."/instances/test/conf", "fasdfsd")
            c:put_key(globals.prefix.."/instances/test/pools/conf", "foobar")
            c:put_key(globals.prefix.."/instances/baz/name", "baz")
            c:put_key(globals.prefix.."/instances/asdf/name", "asdfs")
            globals.cache:purge()

            local list, err = zedcup.instance_list()
            ngx.log(ngx.DEBUG, require("cjson").encode(list))
            if not list then error(err) end

            ngx.say(#list)
            ngx.say(list["test"])
            ngx.say(list["baz"])
            ngx.say(list["asdf"])

            ngx.say(list["foobar"])

            -- iterable
            for _, instance in ipairs(list) do
                ngx.say(instance)
            end

            -- hax, reset the internal lru cache
            globals.cache.lru:flush_all()

            local list, err = zedcup.instance_list()
            ngx.log(ngx.DEBUG, require("cjson").encode(list))
            if not list then error(err) end

            ngx.say(#list)
            ngx.say(list["test"])
            ngx.say(list["baz"])
            ngx.say(list["asdf"])

            ngx.say(list["foobar"])

            -- iterable
            for _, instance in ipairs(list) do
                ngx.say(instance)
            end

        }
    }
--- request
GET /a
--- response_body
0
3
true
true
true
nil
asdf
test
baz
3
true
true
true
nil
asdf
test
baz
--- no_error_log
[error]
[warn]

=== TEST 3: instance configuration
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

            local instance_conf = {
                http = true,

                pools = {
                    {
                        name = "primary",
                        timeout = 100,
                        hosts = {
                            { name = "web01", host = "127.0.0.1", port = "80" },
                            { name = "web02", host = "127.0.0.1", port = "80" }
                        }
                    },
                    {
                        name = "secondary",
                        hosts = {
                        {  name = "dr01", host = "10.10.10.1", port = "80"}

                        }
                    },
                    {
                        name = "tertiary",
                        hosts = {
                            { host = "10.10.10.1", port = "81" }

                        }
                    },
                },
            }

            -- Configure the instance
            local ok, err = zedcup.configure_instance("test", instance_conf)
            if not ok then ngx.say(err) end

            globals.cache:purge()

            local list, err = zedcup.instance_list()
            ngx.log(ngx.DEBUG, require("cjson").encode(list))
            if not list then error(err) end

            ngx.say(list["test"])

            local res, err = c:get_key(globals.prefix.."/instances/test/pools/1/name")
            ngx.say(res.body[1].Value)

            local res, err = c:get_key(globals.prefix.."/instances/test/pools/3/hosts/1/port")
            ngx.say(res.body[1].Value)


            -- Add another instance
            instance_conf["pools"][3] = nil
            instance_conf["https"] = true
            instance_conf["pools"][1]["hosts"][2]["name"] = "new-web02"

            local ok, err = zedcup.configure_instance("test2", instance_conf)
            if not ok then ngx.say(err) end

            globals.cache:purge()

            -- Both show up in list
            local list, err = zedcup.instance_list()
            ngx.log(ngx.DEBUG, require("cjson").encode(list))
            if not list then error(err) end

            ngx.say(list["test"])
            ngx.say(list["test2"])

            local res, err = c:get_key(globals.prefix.."/instances/test/pools/3/name")
            ngx.say(res.body[1].Value)

            local res, err = c:get_key(globals.prefix.."/instances/test2/pools/3/hosts/1/port")
            ngx.say(res.status)

            local res, err = c:get_key(globals.prefix.."/instances/test2/https")
            ngx.say(res.body[1].Value)

            local res, err = c:get_key(globals.prefix.."/instances/test2/pools/1/hosts/2/name")
            ngx.say(res.body[1].Value)
        }
    }
--- request
GET /a
--- response_body
true
primary
81
true
true
tertiary
404
true
new-web02
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

            local cb_res

            -- Bind invalid event
            local ok, err = zedcup.bind("invalid event", function(data)
                cb_res = true
            end)
            ngx.log(ngx.DEBUG, "OK: ", ok, " err: ", err, " cb_res: ", cb_res)
            assert(ok == nil and err ~= nil and cb_res == nil, "Bound invalid event")

            -- Bind invalid cb
            local ok, err = zedcup.bind("invalid event", "test")
            ngx.log(ngx.DEBUG, "OK: ", ok, " err: ", err, " cb_res: ", cb_res)
            assert(ok == nil and err ~= nil, "Bound string cb...")


            -- Valid bind
            local ok, err = zedcup.bind("host_connect", function(instance, data)
                ngx.log(ngx.DEBUG, "callback got instance ", instance, ": ", data)
                cb_res = data
            end)
            ngx.log(ngx.DEBUG, "OK: ", ok, " err: ", err, " cb_res: ", cb_res)
            assert(ok == true and err == nil, "Could not bind host_connect")

            -- Emit the event and check cb was run
            zedcup._emit("host_connect", "dummy", "foobar")
            assert(cb_res == "foobar", "Callback mismatch")

            cb_res = nil

            -- callbacks are pcall'd
            local cb_res2

            local ok, err = zedcup.bind("host_connect", function(instance, data)
                ngx.log(ngx.DEBUG, "callback2 got instance ", instance, ": ", data)
                cb_res2 = data

                local error = 1234 + data -- string + number, throws error

            end)
            ngx.log(ngx.DEBUG, "OK: ", ok, " err: ", err, " cb_res: ", cb_res)
            assert(ok == true and err == nil, "Could not bind host_connect")

            -- Emit the event and check both cbw were run, errors caught
            zedcup._emit("host_connect", "dummy", "foobar2")
            assert(cb_res == "foobar2", "Callback mismatch")
            assert(cb_res2 == "foobar2", "Callback2 mismatch")

            cb_res = nil
            cb_res2 = nil


            -- Bind a different event
            local cb_res3
            local ok, err = zedcup.bind("host_down", function(instance, data)
                ngx.log(ngx.DEBUG, "callback got instance ", instance, ": ", data)
                cb_res3 = data
            end)
            ngx.log(ngx.DEBUG, "OK: ", ok, " err: ", err, " cb_res: ", cb_res)
            assert(ok == true and err == nil, "Could not bind host_down")

            -- Emit the event and check cb was run
            zedcup._emit("host_down", "dummy", "foobar")
            assert(cb_res3 == "foobar", "Callback3 mismatch")

            cb_res3 = nil


            -- CB are run in order
            -- Bind another event
            local ok, err = zedcup.bind("host_down", function(instance, data)
                ngx.log(ngx.DEBUG, "callback got instance ", instance, ": ", data)
                cb_res3 = "override"
            end)
            ngx.log(ngx.DEBUG, "OK: ", ok, " err: ", err, " cb_res: ", cb_res)
            assert(ok == true and err == nil, "Could not bind host_down")

            -- Emit the event and check cb was run
            zedcup._emit("host_down", "dummy", "foobar")
            assert(cb_res3 == "override", "Callback override mismatch")

            cb_res3 = nil

            ngx.say("OK")
        }
    }
--- request
GET /a
--- response_body
OK
--- error_log
Error running global listener

=== TEST 5: init
--- http_config eval: $::AltHttpConfig
--- config
    location = /a {

        content_by_lua_block {
            local zedcup = require("zedcup")
            ngx.say(zedcup.initted())

            local ok, err = zedcup.init({
                dicts = {
                    cache = "missing",
                }
            })
            if not ok then ngx.say(err) else ngx.say("OK") end
            ngx.say(zedcup.initted())

            local ok, err = zedcup.init({
                dicts = {
                    locks = "missing",
                }
            })
            if not ok then ngx.say(err) else ngx.say("OK") end
            ngx.say(zedcup.initted())

            local ok, err = zedcup.init({
                dicts = {
                    ipc = "missing",
                }
            })
            if not ok then ngx.say(err) else ngx.say("OK") end
            ngx.say(zedcup.initted())

            local ok, err = zedcup.init({
                dicts = {
                    cache = "zedcup_alt",
                }
            })
            if not ok then ngx.say(err) else ngx.say("OK") end
            ngx.say(zedcup.initted())
        }
    }
--- request
GET /a
--- response_body
false
[zedcup] cache dictionary not found: missing
false
[zedcup] locks dictionary not found: missing
false
[zedcup] ipc dictionary not found: missing
false
OK
true
--- no_error_log
[error]
[warn]

=== TEST 6: remove instance
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

            local instance_conf = {
                http = true,

                pools = {
                    {
                        name = "primary",
                        timeout = 100,
                        hosts = {
                            { name = "web01", host = "127.0.0.1", port = "80" },
                            { name = "web02", host = "127.0.0.1", port = "80" }
                        }
                    },
                    {
                        name = "secondary",
                        hosts = {
                        {  name = "dr01", host = "10.10.10.1", port = "80"}

                        }
                    },
                    {
                        name = "tertiary",
                        hosts = {
                            { host = "10.10.10.1", port = "81" }

                        }
                    },
                },
            }

            -- Configure the instance
            local ok, err = zedcup.configure_instance("test", instance_conf)
            if not ok then ngx.say(err) end


            -- Add another instance
            instance_conf["pools"][3] = nil
            instance_conf["https"] = true
            instance_conf["pools"][1]["hosts"][2]["name"] = "new-web02"

            local ok, err = zedcup.configure_instance("test2", instance_conf)
            if not ok then ngx.say(err) end

            globals.cache:purge()

            -- Both show up in list
            local list, err = zedcup.instance_list()
            ngx.log(ngx.DEBUG, require("cjson").encode(list))
            if not list then error(err) end

            ngx.say(list["test"])
            ngx.say(list["test2"])

            local ok, err = zedcup.remove_instance("test")
            ngx.say(ok, " ", err)

            globals.cache:purge()

            local list, err = zedcup.instance_list()
            ngx.log(ngx.DEBUG, require("cjson").encode(list))
            if not list then error(err) end

            ngx.say(list["test"])
            ngx.say(list["test2"])
        }
    }
--- request
GET /a
--- response_body
true
true
true nil
nil
true
--- no_error_log
[error]
[warn]
