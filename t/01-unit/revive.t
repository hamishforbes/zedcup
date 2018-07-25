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
                                path = "/_health"
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
=== TEST 1: down hosts are revived
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

            local tbl_copy = require("zedcup.utils").tbl_copy
            local conf = tbl_copy(DEFAULT_CONF)

            -- Set hosts down
            conf.pools[1].hosts[1].up = false
            conf.pools[1].hosts[2].up = false
            conf.pools[3].hosts[1].up = false

            -- Configure the instances
            local ok, err = zedcup.configure_instance("test", conf)
            if not ok then ngx.say(err) end

            local ok, err = zedcup.configure_instance("test2", conf)
            if not ok then ngx.say(err) end

            -- Fake state entries
            local flag = ngx.time() - 61
            c:put_key(globals.prefix.."/state/test/1/1/error_count", 999, {flags = flag} )
            c:put_key(globals.prefix.."/state/test/1/2/error_count", 999, {flags = flag} )
            c:put_key(globals.prefix.."/state/test/3/1/error_count", 999, {flags = flag} )
            c:put_key(globals.prefix.."/state/test2/1/1/error_count", 999, {flags = flag} )
            c:put_key(globals.prefix.."/state/test2/1/2/error_count", 999, {flags = flag} )
            c:put_key(globals.prefix.."/state/test2/3/1/error_count", 999, {flags = ngx.time()} )

            local handler = zedcup.create_handler("test")
            local handler2 = zedcup.create_handler("test2")
            local c = handler:config()
            local c2 = handler2:config()
            local s = handler:state()
            local s2 = handler2:state()

            ngx.say("test host: ", c.pools[1].hosts[1].up, " (", type(c.pools[1].hosts[1].up), ")")
            ngx.say("test host3/1: ", c.pools[3].hosts[1].up, " (", type(c.pools[3].hosts[1].up), ")")
            ngx.say("test2 host: ", c2.pools[1].hosts[1].up, " (", type(c2.pools[1].hosts[1].up), ")")
            ngx.say("test2 host3/1: ", c2.pools[3].hosts[1].up, " (", type(c2.pools[3].hosts[1].up), ")")
            ngx.say("test state: ", s[1][1].error_count)
            ngx.say("test state3/1: ", s[3][1].error_count)
            ngx.say("test2 state: ", s2[1][1].error_count)
            ngx.say("test2 state3/1: ", s2[3][1].error_count)


            local revived = {}

            zedcup.bind("host_up", function(instance, data)
                ngx.log(ngx.DEBUG, "BIND CALLBACK")
                table.insert(revived, instance..":"..data.pool.name.."/"..data.host.name)
            end)

            local revive = require("zedcup.worker.revive")

            -- Run the revive worker inline
            local ok, err = revive._revive()
            if err then error(err) end
            ngx.say("OK: ", ok)

            globals.cache:purge()

            local c = handler:config()
            local c2 = handler2:config()
            local s = handler:state()
            local s2 = handler2:state()


            ngx.say("test host: ", c.pools[1].hosts[1].up, " (", type(c.pools[1].hosts[1].up), ")")
            ngx.say("test host3/1: ", c.pools[3].hosts[1].up, " (", type(c.pools[3].hosts[1].up), ")")
            ngx.say("test2 host: ", c2.pools[1].hosts[1].up, " (", type(c2.pools[1].hosts[1].up), ")")
            ngx.say("test2 host3/1: ", c2.pools[3].hosts[1].up, " (", type(c2.pools[3].hosts[1].up), ")")
            ngx.say("test state: ", s)
            ngx.say("test2 state: ", s2[1])
            ngx.say("test2 state3/1: ", s2[3][1].error_count)

            ngx.say(#revived)
            table.sort(revived)
            for _, v in ipairs(revived) do
                ngx.say(v)
            end

        }
    }
--- request
GET /a
--- response_body
test host: false (boolean)
test host3/1: false (boolean)
test2 host: false (boolean)
test2 host3/1: false (boolean)
test state: 999
test state3/1: 999
test2 state: 999
test2 state3/1: 999
OK: true
test host: true (boolean)
test host3/1: true (boolean)
test2 host: true (boolean)
test2 host3/1: false (boolean)
test state: nil
test2 state: nil
test2 state3/1: 999
5
test2:primary/web01
test2:primary/web02
test:primary/web01
test:primary/web02
test:tertiary/1
--- no_error_log
[error]
[warn]
