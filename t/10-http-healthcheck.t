# vim:set ft= ts=4 sw=4 et:

use Test::Nginx::Socket;
use Cwd qw(cwd);

plan tests => repeat_each() * 39;

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
        upstream_http  = require("resty.upstream.http")
        upstream_api = require("resty.upstream.api")

        upstream, configured = upstream_socket:new({ dict = "test_upstream" })
        test_api = upstream_api:new(upstream)
        http = upstream_http:new(upstream)

        test_api:create_pool({id = "primary", timeout = 100, read_timeout = 1100, keepalive_timeout = 1, status_codes = {["5xx"] = true} })

        test_api:create_pool({id = "secondary", timeout = 100, priority = 10, status_codes = {["5xx"] = true}})
};

$ENV{TEST_NGINX_RESOLVER} = '8.8.8.8';

no_long_string();
#no_diff();

run_tests();

__DATA__
=== TEST 1: Default background check is sent - true
--- http_config eval
"$::HttpConfig"
."$::InitConfig"
. q{
            test_api:add_host("primary", { id="a", host = "127.0.0.1", port = $TEST_NGINX_SERVER_PORT, weight = 1, healthcheck = true })
    ';
}
--- config
    location = / {
        content_by_lua '
            ngx.log(ngx.ERR, "Background check received")
        ';
    }
    location = /foo {
        content_by_lua '
            http:_http_background_func()
        ';
    }
--- request
GET /foo
--- error_log: Background check received

=== TEST 1b: Default background check is sent - table
--- http_config eval
"$::HttpConfig"
."$::InitConfig"
. q{
            test_api:add_host("primary", { id="a", host = "127.0.0.1", port = $TEST_NGINX_SERVER_PORT, weight = 1, healthcheck = {} })
    ';
}
--- config
    location = / {
        content_by_lua '
            ngx.log(ngx.ERR, "Background check received")
        ';
    }
    location = /foo {
        content_by_lua '
            http:_http_background_func()
        ';
    }
--- request
GET /foo
--- error_log: Background check received

=== TEST 1c: Default background check can be disabled - nil
--- http_config eval
"$::HttpConfig"
."$::InitConfig"
. q{
            test_api:add_host("primary", { id="a", host = "127.0.0.1", port = $TEST_NGINX_SERVER_PORT, weight = 1, healthcheck = nil })
    ';
}
--- config
    location = / {
        content_by_lua '
            ngx.log(ngx.ERR, "Background check received")
        ';
    }
    location = /foo {
        content_by_lua '
            http:_http_background_func() -- Should not fire background check
            ngx.log(ngx.ERR, "Second log entry")
        ';
    }
--- request
GET /foo
--- no_error_log: Background check received
--- error_log: Second log entry

=== TEST 1d: Default background check can be disabled - false
--- http_config eval
"$::HttpConfig"
."$::InitConfig"
. q{
            test_api:add_host("primary", { id="a", host = "127.0.0.1", port = $TEST_NGINX_SERVER_PORT, weight = 1, healthcheck = false })
    ';
}
--- config
    location = / {
        content_by_lua '
            ngx.log(ngx.ERR, "Background check received")
        ';
    }
    location = /foo {
        content_by_lua '
            http:_http_background_func() -- Should not fire background check
            ngx.log(ngx.ERR, "Second log entry")
        ';
    }
--- request
GET /foo
--- no_error_log: Background check received
--- error_log: Second log entry

=== TEST 2: Custom background check params
--- http_config eval
"$::HttpConfig"
."$::InitConfig"
. q{
            test_api:add_host("primary", {
                 id="a", host = "127.0.0.1", port = $TEST_NGINX_SERVER_PORT, weight = 1,
                 healthcheck = {
                    path = "/check",
                    headers = {
                        ["User-Agent"] = "Test-Agent"
                    }
                 }
                })
    ';
}
--- config
    location = /check {
        content_by_lua '
            local headers = ngx.req.get_headers()
            ngx.log(ngx.ERR, "Background check received from "..headers["User-Agent"])
        ';
    }
    location = /foo {
        content_by_lua '
            http:_http_background_func()
       ';
    }
--- request
GET /foo
--- error_log: Background check received from Test-Agent

=== TEST 3: Background check marks timeout host failed
--- http_config eval
"$::HttpConfig"
."$::InitConfig"
. q{
            test_api:add_host("primary", { id="a", host = "127.0.0.1", port = 8$TEST_NGINX_SERVER_PORT, weight = 1, healthcheck = true })
    ';
}
--- config
    location = / {
        content_by_lua '
            http:_http_background_func()
            -- Run process_failed_hosts inline rather than after the request is done
            upstream._process_failed_hosts(false, upstream, upstream:ctx())

            local pools, err = upstream:get_pools()
            local idx = upstream.get_host_idx("a", pools.primary.hosts)
            local host = pools.primary.hosts[idx]
            if host.failcount ~= 1 then
                ngx.status = 500
            end

        ';
    }
--- request
GET /
--- error_code: 200

=== TEST 4: Background check marks http error host failed
--- http_config eval
"$::HttpConfig"
."$::InitConfig"
. q{
            test_api:add_host("primary", { id="a", host = "127.0.0.1", port = $TEST_NGINX_SERVER_PORT, weight = 1, healthcheck = true })
    ';
}
--- config
    location = / {
        return 500;
    }
    location = /foo {
        content_by_lua '
            http:_http_background_func()
            -- Run process_failed_hosts inline rather than after the request is done
            upstream._process_failed_hosts(false, upstream, upstream:ctx())

            local pools, err = upstream:get_pools()
            local idx = upstream.get_host_idx("a", pools.primary.hosts)
            local host = pools.primary.hosts[idx]
            if host.failcount ~= 1 then
                ngx.status = 500
            end

        ';
    }
--- request
GET /foo
--- error_code: 200

=== TEST 5: Succesful healthcheck request doesn't affect host
--- http_config eval
"$::HttpConfig"
."$::InitConfig"
. q{
            test_api:add_host("primary", { id="a", host = "127.0.0.1", port = $TEST_NGINX_SERVER_PORT, weight = 1, healthcheck = true })
    ';
}
--- config
    location = / {
        return 200;
    }
    location = /foo {
        content_by_lua '
            http:_http_background_func()
            -- Run process_failed_hosts inline rather than after the request is done
            upstream._process_failed_hosts(false, upstream, upstream:ctx())

            local pools, err = upstream:get_pools()
            local idx = upstream.get_host_idx("a", pools.primary.hosts)
            local host = pools.primary.hosts[idx]
            if host.failcount ~= 0 then
                ngx.status = 500
            end

        ';
    }
--- request
GET /foo
--- error_code: 200

=== TEST 6: Custom healthcheck interval
--- http_config eval
"$::HttpConfig"
."$::InitConfig"
. q{
            test_api:add_host("primary", { id="a", host = "127.0.0.1", port = $TEST_NGINX_SERVER_PORT, weight = 1, healthcheck = {interval = 2} })
    ';
}
--- config
    location = / {
        content_by_lua '
            local first = ngx.shared.test_upstream:get("first_flag")

            if not first then
                ngx.shared.test_upstream:set("first_flag", true)
                ngx.log(ngx.ERR, "Background check received")
            else
                ngx.log(ngx.ERR, "Second Background check received")
            end
        ';
    }
    location = /foo {
        content_by_lua '
            http:_http_background_func()
            ngx.sleep(2)
            http:_http_background_func()
        ';
    }
--- request
GET /foo
--- error_log: Background check received
--- error_log: Second Background check received

=== TEST 6: Required healthcheck values get set
--- http_config eval
"$::HttpConfig"
."$::InitConfig"
. q{
            test_api:add_host("primary", { id="a", host = "127.0.0.1", port = $TEST_NGINX_SERVER_PORT, weight = 1, healthcheck = true })
    ';
}
--- config
    location = / {
        content_by_lua '
            ngx.shared.test_upstream:set("first_flag", true)
            ngx.log(ngx.ERR, "Background check received")
        ';
    }
    location = /foo {
        content_by_lua '
            http:_http_background_func()

            local pools, err = upstream:get_pools()
            local idx = upstream.get_host_idx("a", pools.primary.hosts)
            local host = pools.primary.hosts[idx]
            ngx.print(host.healthcheck.interval)
            if host.healthcheck.last_check then
                ngx.print(" last_check")
            end
        ';
    }
--- request
GET /foo
--- error_log: Background check received
--- response_body: 60 last_check

=== TEST 7: Default background check params are set - bool
--- http_config eval
"$::HttpConfig"
."$::InitConfig"
. q{
            test_api:add_host("primary", {
                 id="a", host = "127.0.0.1", port = $TEST_NGINX_SERVER_PORT, weight = 1,
                 healthcheck = true
                })
    ';
}
--- config
    location = / {
        content_by_lua '
            local headers = ngx.req.get_headers()
            ngx.log(ngx.ERR, "Background check received from "..headers["User-Agent"])
        ';
    }
    location = /foo {
        content_by_lua '
            http:_http_background_func()
       ';
    }
--- request
GET /foo
--- error_log: Background check received from Resty Upstream

=== TEST 7b: Default background check params are set - table
--- http_config eval
"$::HttpConfig"
."$::InitConfig"
. q{
            test_api:add_host("primary", {
                 id="a", host = "127.0.0.1", port = $TEST_NGINX_SERVER_PORT, weight = 1,
                 healthcheck = { path = "/check" }
                })
    ';
}
--- config
    location = /check {
        content_by_lua '
            local headers = ngx.req.get_headers()
            ngx.log(ngx.ERR, "Background check received from "..headers["User-Agent"])
        ';
    }
    location = /foo {
        content_by_lua '
            http:_http_background_func()
       ';
    }
--- request
GET /foo
--- error_log: Background check received from Resty Upstream

=== TEST 7c: Default background check params are set - custom headers
--- http_config eval
"$::HttpConfig"
."$::InitConfig"
. q{
            test_api:add_host("primary", {
                 id="a", host = "127.0.0.1", port = $TEST_NGINX_SERVER_PORT, weight = 1,
                 healthcheck = {
                    path = "/check",
                    headers = {
                        ["X-Foo"] = "baz"
                    }
                 }
                })
    ';
}
--- config
    location = /check {
        content_by_lua '
            local headers = ngx.req.get_headers()
            ngx.log(ngx.ERR, "Background check received from "..headers["User-Agent"])
            ngx.log(ngx.ERR, "X-Foo: "..headers["X-Foo"])
        ';
    }
    location = /foo {
        content_by_lua '
            http:_http_background_func()
       ';
    }
--- request
GET /foo
--- error_log: Background check received from Resty Upstream
--- error_log: X-Foo: baz

=== TEST 8: Healthcheck read timeout overrides pool
--- http_config eval
"$::HttpConfig"
."$::InitConfig"
. q{
            test_api:add_host("primary", { id="a", host = "127.0.0.1", port = $TEST_NGINX_SERVER_PORT, weight = 1, healthcheck = {  path = "/check", read_timeout = 100 } })
    ';
}
--- config
    location = / {
        content_by_lua '
            ngx.update_time()
            local start = ngx.now()

            http:_http_background_func()

            ngx.update_time()
            local stop = ngx.now()
            local duration = stop - start

            -- Pool timeout is 1100
            if duration > 0.50 then
                ngx.say("Fail")
            else
                ngx.say("OK")
            end
        ';
    }
    location = /check {
        content_by_lua '
            ngx.sleep(900)
            ngx.say("OK")
        ';
    }
--- request
GET /
--- error_code: 200
--- response_body
OK

=== TEST 8b: Healthcheck read timeout doesn't affect frontend
--- http_config eval
"$::HttpConfig"
."$::InitConfig"
. q{
            test_api:add_host("primary", { id="a", host = "127.0.0.1", port = $TEST_NGINX_SERVER_PORT, weight = 1, healthcheck = {  path = "/check", read_timeout = 100 } })
    ';
}
--- config
    location = / {
        content_by_lua '
            ngx.update_time()
            local start = ngx.now()

            local ok, err = http:request({path = "/check"})

            ngx.update_time()
            local stop = ngx.now()
            local duration = stop - start

            -- Pool timeout is 1100
            if duration < 0.80 then
                ngx.say("Fail")
            else
                ngx.say("OK")
            end
        ';
    }
    location = /check {
        content_by_lua '
            ngx.sleep(900)
            ngx.say("OK")
        ';
    }
--- request
GET /
--- error_code: 200
--- response_body
OK

=== TEST 9: Healthcheck connect timeout overrides pool
--- http_config eval
"$::HttpConfig"
."$::InitConfig"
. q{
            test_api:add_host("primary", { id="a", host = "10.123.123.123", port = $TEST_NGINX_SERVER_PORT, weight = 1, healthcheck = { timeout = 10 } })
    ';
}
--- config
    location = / {
        content_by_lua '
            ngx.update_time()
            local start = ngx.now()

            http:_http_background_func()

            ngx.update_time()
            local stop = ngx.now()
            local duration = stop - start

            -- Pool timeout is 100
            if duration > 0.05 then
                ngx.say("Fail")
            else
                ngx.say("OK")
            end
        ';
    }
--- request
GET /
--- error_code: 200
--- response_body
OK

=== TEST 9b: Healthcheck connect timeout doesn't affect frontend
--- http_config eval
"$::HttpConfig"
."$::InitConfig"
. q{
            test_api:add_host("primary", { id="a", host = "10.123.123.123", port = $TEST_NGINX_SERVER_PORT, weight = 1, healthcheck = { timeout = 10 } })
    ';
}
--- config
    location = / {
        content_by_lua '
            ngx.update_time()
            local start = ngx.now()

            local ok, err = http:request({path = "/check"})

            ngx.update_time()
            local stop = ngx.now()
            local duration = stop - start

            -- Pool timeout is 100
            if duration < 0.05 then
                ngx.say("Fail")
            else
                ngx.say("OK")
            end
        ';
    }
--- request
GET /
--- error_code: 200
--- response_body
OK


=== TEST 10: Healthcheck status_codes override pool
--- http_config eval
"$::HttpConfig"
."$::InitConfig"
. q{
            test_api:add_host("primary", { id="a", host = "127.0.0.1", port = $TEST_NGINX_SERVER_PORT, weight = 1, healthcheck = {  path = "/check", status_codes = {["403"] = true} } })
    ';
}
--- config
    location = / {
        content_by_lua '
            http:_http_background_func()

            -- Run process_failed_hosts inline rather than after the request is done
            upstream._process_failed_hosts(false, upstream, upstream:ctx())

            local pools, err = upstream:get_pools()
            local idx = upstream.get_host_idx("a", pools.primary.hosts)
            local host = pools.primary.hosts[idx]
            if host.failcount ~= 1 then
                ngx.status = 500
            end
        ';
    }
    location = /check {
        content_by_lua '
            ngx.status = 403
            ngx.say("OK")
        ';
    }
--- request
GET /
--- error_code: 200
--- error_log: HTTP 403 from Host "a"

=== TEST 10b: Healthcheck status_codes doesn't affect frontend
--- http_config eval
"$::HttpConfig"
."$::InitConfig"
. q{
            test_api:add_host("primary", { id="a", host = "127.0.0.1", port = $TEST_NGINX_SERVER_PORT, weight = 1, healthcheck = {  path = "/check", status_codes = {["403"] = true} } })
    ';
}
--- config
    location = / {
        content_by_lua '
            local res, err = http:request({path = "/check"})
            if not res then
                ngx.status = err.status
                ngx.say(err.err)
                return ngx.exit(ngx.status)
            end
            ngx.say(res.status)
        ';
    }
    location = /check {
        content_by_lua '
            ngx.status = 403
            ngx.say("OK")
        ';
    }
--- request
GET /
--- error_code: 200
--- no_error_log: HTTP 403 from Host "a"
--- response_body
403
