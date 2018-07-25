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

run_tests();

__DATA__
=== TEST 1: worker locks
--- http_config eval: $::HttpConfig
--- config
    location = /a {
        content_by_lua_block {
            local lock = require("zedcup.locks").worker
            local globals = require("zedcup").globals()

            local ok, err = lock.acquire("test")
            if err then error(err) end
            ngx.say(ok)

            local ok, err = lock.acquire("test")
            if err then error(err) end
            ngx.say(ok)

            local ok, err = lock.acquire("test2")
            if err then error(err) end
            ngx.say(ok)

            local ok, err = lock.release("test")
            if err then error(err) end
            ngx.say(ok)

            local ok, err = lock.acquire("test2")
            if err then error(err) end
            ngx.say(ok)

            local ok, err = lock.acquire("test")
            if err then error(err) end
            ngx.say(ok)

            local ok, err = lock.release("test")
            if err then error(err) end
            ngx.say(ok)

            local ok, err = lock.release("test2")
            if err then error(err) end
            ngx.say(ok)

        }
    }
--- request
GET /a
--- response_body
true
false
true
true
false
true
true
true
--- no_error_log
[error]
[warn]


=== TEST 2: worker lock errors
--- http_config eval: $::HttpConfig
--- config
    location = /a {
        content_by_lua_block {
            local lock = require("zedcup.locks").worker
            local globals = require("zedcup").globals()
            local dict = globals.dicts["locks"]

            local ok, err = pcall(lock.acquire)
            ngx.log(ngx.DEBUG, ok, ": ", err)
            assert(not ok and err, "Acquire, no key provided")


            local ok, err = pcall(lock.release)
            ngx.log(ngx.DEBUG, ok, ": ", err)
            assert(not ok and err, "Release, no key provided")


            local ok, err = pcall(lock.acquire, {})
            ngx.log(ngx.DEBUG, ok, ": ", err)
            assert(not ok and err, "Acquire, table key")

            local ok, err = pcall(lock.release, {})
            ngx.log(ngx.DEBUG, ok, ": ", err)
            assert(not ok and err, "Release, table key")


            local ok, err= pcall(lock.release, "foobar")
            ngx.log(ngx.DEBUG, ok, ": ", err)
            assert(err == false, "Release, invalid key")


            -- Acquire lock then delete it
            local ok, err = lock.acquire("test")
            if err then error(err) end
            ngx.say(ok)

            dict:delete("zedcup_worker_lock_test")

            local ok, err= pcall(lock.release, "test")
            ngx.log(ngx.DEBUG, ok, ": ", err)
            assert(err == false, "Release, deleted key")


            -- Acquire lock then modify it
            local ok, err = lock.acquire("test")
            if err then error(err) end
            ngx.say(ok)

            dict:set("zedcup_worker_lock_test", "asdfsd")

            local ok, err= pcall(lock.release, "test")
            ngx.log(ngx.DEBUG, ok, ": ", err)
            assert(err == false, "Release, mismatch key")

        }
    }
--- request
GET /a
--- response_body
true
true
--- no_error_log
[error]
[warn]


=== TEST 3: worker lock expiry
--- http_config eval: $::HttpConfig
--- config
    location = /a {
        content_by_lua_block {
                 local lock = require("zedcup.locks").worker
            local globals = require("zedcup").globals()
            local dict = globals.dicts["locks"]

            local ok, err = lock.acquire("test", 1)
            if err then error(err) end
            ngx.say(ok)

            ngx.sleep(1.1) -- wait for lock to expire

            local ok, err= pcall(lock.release, "test")
            ngx.log(ngx.DEBUG, ok, ": ", err)
            assert(err == false, "Release, deleted key")

        }
    }
--- request
GET /a
--- response_body
true
--- no_error_log
[error]
[warn]
