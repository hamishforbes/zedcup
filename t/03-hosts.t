# vim:set ft= ts=4 sw=4 et:

use Test::Nginx::Socket;
use Cwd qw(cwd);

plan tests => repeat_each() * 15;

my $pwd = cwd();

our $HttpConfig = qq{
    lua_package_path "$pwd/lib/?.lua;;";
    error_log logs/error.log debug;

    lua_shared_dict test_upstream 1m;


};

our $InitConfig = qq{
    init_by_lua '
        cjson = require "cjson"
        upstream_socket  = require("resty.upstream.socket")
        upstream_api = require("resty.upstream.api")

        upstream, configured = upstream_socket:new({ dict = "test_upstream" })
        test_api = upstream_api:new(upstream)

        test_api:create_pool({id = "primary", timeout = 100})

        test_api:create_pool({id = "secondary", timeout = 100, priority = 10})
};

$ENV{TEST_NGINX_RESOLVER} = '8.8.8.8';

no_long_string();
#no_diff();

run_tests();

__DATA__
=== TEST 1: Connecting to a single host
--- http_config eval
"$::HttpConfig"
."$::InitConfig"
. q{
        test_api:add_host("primary", { id="a", host = "127.0.0.1", port = $TEST_NGINX_SERVER_PORT, weight = 1 })
    ';
}
--- log_level: debug
--- config
    location = / {
        content_by_lua '

            local ok, err = upstream:connect()
            if ok then
                ngx.say("OK")
            else
                ngx.say(cjson.encode(err))
            end
        ';
    }
--- request
GET /
--- no_error_log
[error]
[warn]
--- response_body
OK

=== TEST 2: Mark single host down after 3 fails
--- http_config eval
"$::HttpConfig"
."$::InitConfig"
. q{
        test_api:add_host("primary", { id="a", host = "127.0.0.1", port = 8$TEST_NGINX_SERVER_PORT, weight = 1 })
    ';
}
--- config
    location = / {
        content_by_lua '
            -- Simulate 3 connection attempts
            for i=1,3 do
                upstream:connect()
                -- Run process_failed_hosts inline rather than after the request is done
                upstream._process_failed_hosts(false, upstream, upstream:ctx())
            end

            pools = upstream:get_pools()

            local idx = upstream.get_host_idx("a", pools.primary.hosts)
            if pools.primary.hosts[idx].up then
                ngx.status = 500
                ngx.say("FAIL")
            else
                ngx.status = 200
                ngx.say("OK")
            end
            ngx.exit(ngx.status)
        ';
    }
--- request
GET /
--- response_body
OK

=== TEST 3: Mark round_robin host down after 3 fails
--- http_config eval
"$::HttpConfig"
."$::InitConfig"
. q{
        test_api:add_host("primary", { id="a", host = "127.0.0.1", port = 8$TEST_NGINX_SERVER_PORT, weight = 9999 })
        test_api:add_host("primary", { id="b", host = "127.0.0.1", port = 8$TEST_NGINX_SERVER_PORT, weight = 1 })
    ';
}
--- config
    location = / {
        content_by_lua '


            -- Simulate 3 connection attempts
            for i=1,3 do
                upstream:connect()
                -- Run process_failed_hosts inline rather than after the request is done
                upstream._process_failed_hosts(false, upstream, upstream:ctx())
            end

            pools = upstream:get_pools()

            local idx = upstream.get_host_idx("a", pools.primary.hosts)
            if pools.primary.hosts[idx].up then
                ngx.say("FAIL")
                ngx.status = 500
            else
                ngx.say("OK")
                ngx.status = 200
            end
            ngx.exit(ngx.status)
        ';
    }
--- request
GET /
--- response_body
OK

=== TEST 4: Manually offline hosts are not reset
--- http_config eval
"$::HttpConfig"
."$::InitConfig"
. q{
        test_api:add_host("primary", { id="a", host = "127.0.0.1", port = 8$TEST_NGINX_SERVER_PORT, weight = 1 })
    ';
}
--- config
    location = / {
        content_by_lua '
            test_api:down_host("primary", "a")
            upstream:revive_hosts()

            local pools, err = upstream:get_pools()
            local idx = upstream.get_host_idx("a", pools.primary.hosts)
            local host = pools.primary.hosts[idx]
            if host.up  ~= false then
                ngx.status = 500
            end
        ';
    }
--- request
GET /
--- error_code: 200

=== TEST 5: Manually offline hosts are not reset after a natural fail
--- http_config eval
"$::HttpConfig"
."$::InitConfig"
. q{
        test_api:add_host("primary", { id="a", host = "127.0.0.1", port = 8$TEST_NGINX_SERVER_PORT, weight = 1 })
    ';
}
--- config
    location = / {
        content_by_lua '
            local pools = upstream:get_pools()
            local idx = upstream.get_host_idx("a", pools.primary.hosts)
            local host = pools.primary.hosts[idx]

            host.failcount = 1
            host.lastfail = ngx.now() - (pools.primary.failed_timeout+1)
            upstream:save_pools(pools)

            test_api:down_host("primary", "a")
            upstream:revive_hosts()

            local pools, err = upstream:get_pools()
            local idx = upstream.get_host_idx("a", pools.primary.hosts)
            local host = pools.primary.hosts[idx]
            if host.up ~= false then
                ngx.status = 500
            end
        ';
    }
--- request
GET /
--- error_code: 200

=== TEST 6: Offline hosts are reset by background function
--- http_config eval
"$::HttpConfig"
."$::InitConfig"
. q{
        test_api:add_host("primary", { id="a", host = "127.0.0.1", port = 8$TEST_NGINX_SERVER_PORT, weight = 1 })
    ';
}
--- config
    location = / {
        content_by_lua '
            local pools = upstream:get_pools()
            local idx = upstream.get_host_idx("a", pools.primary.hosts)
            local host = pools.primary.hosts[idx]

            host.up = false
            host.failcount = pools.primary.max_fails +1
            host.lastfail = ngx.now() - (pools.primary.failed_timeout+1)
            upstream:save_pools(pools)

            upstream:revive_hosts()

            local pools, err = upstream:get_pools()
            local idx = upstream.get_host_idx("a", pools.primary.hosts)
            local host = pools.primary.hosts[idx]

            if host.up == false or host.failcount ~= 0 or host.lastfail ~= 0 then
                ngx.status = 500
            end
        ';
    }
--- request
GET /
--- error_code: 200

=== TEST 7: Do not attempt connection to single host which is down
--- http_config eval
"$::HttpConfig"
."$::InitConfig"
. q{
        test_api:add_host("primary", { id="a", host = "127.0.0.1", port = $TEST_NGINX_SERVER_PORT, weight = 1 })
    ';
}
--- log_level: debug
--- config
    location = / {
        content_by_lua '
            test_api:down_host("primary", "a")

            local ok, err = upstream:connect()
            if not ok then
                ngx.say("OK")
            else
                ngx.say(cjson.encode(err))
            end
        ';
    }
--- request
GET /
--- no_error_log
[error]
[warn]
--- response_body
OK
