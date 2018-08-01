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
no_root_location();

our $HttpConfig = qq{
    lua_package_path "$pwd/lib/?.lua;;";
    error_log logs/error.log debug;

    lua_shared_dict zedcup_cache 1m;
    lua_shared_dict zedcup_locks 1m;
    lua_shared_dict zedcup_ipc 1m;

    lua_socket_log_errors off;

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
            healthcheck = {
                path = "/_instance_check"
            },
            pools = {
                {
                    healthcheck = true,
                    name = "primary",
                    timeout = 100,
                    hosts = {
                        { name = "web01", host = "127.0.0.1", port = TEST_NGINX_PORT },
                        {
                            name = "web02", host = "127.0.0.1", port = TEST_NGINX_PORT,
                            healthcheck = {
                                path = "/_health"
                            }
                        }
                    }
                },
                {
                    hosts = {
                    {  name = "dr01", host = "127.0.0.1", port = TEST_NGINX_PORT}

                    }
                },
                {
                    name = "tertiary",
                    hosts = {
                        { host = "127.0.0.1", port = TEST_NGINX_PORT+1, healthcheck = true, }

                    }
                },
            },
        }

    }

};

run_tests();

__DATA__
=== TEST 1: healthchecks
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


            -- bind to events
            local req_err = {}
            local ok, err = zedcup.bind("host_request_error", function(instance, data)
                ngx.log(ngx.DEBUG, "REQ ", instance, ": ", require("cjson").encode(data) )
                table.insert(req_err, instance..":"..data.host._pool.name.."/"..data.host.name.." : "..data.err)
            end)
            if err then error(err) end

            local conn_err = {}
            local ok, err = zedcup.bind("host_connect_error", function(instance, data)
                ngx.log(ngx.DEBUG, "CONN ", instance, ": ", require("cjson").encode(data) )
                table.insert(conn_err, instance..":"..data.host._pool.name.."/"..data.host.name.." : "..data.err)
            end)
            if err then error(err) end

            local healthcheck = require("zedcup.worker.healthcheck")._healthcheck

            local ok, err = healthcheck(false)

            table.sort(req_err)
            table.sort(conn_err)

            for _, err in pairs(req_err) do ngx.say("Request err: ", err) end
            for _, err in pairs(conn_err) do ngx.say("Connect err: ", err) end

            -- Check state was persisted
            local res, err = c:get_key(globals.prefix.."/state/test/1/2/error_count")
            if err then error(err) end
            ngx.say(res.body[1].Value)

            local res, err = c:get_key(globals.prefix.."/state/test/1/1/last_check")
            if err then error(err) end
            ngx.say(tonumber(res.body[1].Value) == ngx.time())

            local res, err = c:get_key(globals.prefix.."/state/test/2/1/last_check")
            if err then error(err) end
            if res.status == 200 then
                ngx.say(tonumber(res.body[1].Value) == ngx.time())
            else
                ngx.say("fail")
            end

            local res, err = c:get_key(globals.prefix.."/state/test2/3/1/error_count")
            if err then error(err) end
            ngx.say(res.body[1].Value)

            local res, err = c:get_key(globals.prefix.."/state/test2/3/1/last_check")
            if err then error(err) end
            ngx.say(tonumber(res.body[1].Value) == ngx.time())

        }
    }

location = / {
    echo "OK";
}

location = /_instance_check {
    content_by_lua_block {
        ngx.say("OK INSTANCE")
        ngx.log(ngx.DEBUG, "Instance Healthcheck")
    }
}

location = /_health {
    content_by_lua_block {
        ngx.status = 500
        ngx.say("BAD")
        ngx.exit(ngx.status)
    }
}
--- request
GET /a
--- response_body
Request err: test2:primary/web02 : Bad status code: 500
Request err: test:primary/web02 : Bad status code: 500
Connect err: test2:tertiary/1 : connection refused
Connect err: test:tertiary/1 : connection refused
1
true
true
1
true
--- no_error_log
[error]
[warn]
--- error_log
Instance Healthcheck
