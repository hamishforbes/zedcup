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
            pools = {
                {
                    name = "primary",
                    timeout = 100,
                    healthcheck = {
                        status_codes = {"50x"},
                        path = "/_healthcheck"
                    },
                    hosts = {
                        { name = "web01", host = "127.0.0.1", port = TEST_NGINX_PORT },
                        { name = "web02", host = "127.0.0.1", port = TEST_NGINX_PORT }
                    }
                },
                {
                    name = "secondary",
                    hosts = {
                        { name = "dr01", host = "127.0.0.1", port = TEST_NGINX_PORT}
                    }
                },
            }
        }

    }

    init_worker_by_lua_block {
        ngx.timer.at(0, function()
            if require("zedcup.locks").worker.acquire("bootstrap") then
                local c = require("resty.consul"):new({
                    host = TEST_CONSUL_HOST,
                    port = TEST_CONSUL_port,
                })

                -- Clear up before running tests
                local prefix = require("zedcup").globals().prefix
                c:delete_key(prefix, {recurse = true})

                -- Configure the instance
                local ok, err = require("zedcup").configure_instance("test", DEFAULT_CONF)
                if not ok then error(err) end
            end
        end)

        require("zedcup").run_workers()
    }

};

run_tests();

__DATA__
=== TEST 1: Basic
--- http_config eval: $::HttpConfig
--- config
    location = /a {
        content_by_lua_block {
            local handler = require("zedcup").create_handler("test")

            local connected_host
            assert(handler:bind("host_connect", function(data)
                connected_host = data.pool.name.."/"..data.host.name
            end), "Bind failed")

            local res, err = handler:request({ path = "/test" })
            assert(res, "Res is nil: "..tostring(err) )

            local body = res:read_body()
            ngx.say(connected_host)

            ngx.say(res.status)
            ngx.print(body)

        }
    }

    location /test {
        echo "TEST OK";
    }
    location /_healthcheck {
        echo "HEALTHCHECK OK";
    }
--- request eval
["GET /a", "GET /a"]
--- response_body eval
[
"primary/web01
200
TEST OK
",
"primary/web02
200
TEST OK
",
]
--- no_error_log
[error]
[warn]
