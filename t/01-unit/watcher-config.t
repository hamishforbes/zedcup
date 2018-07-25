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
=== TEST 1: Config watcher
--- http_config eval: $::HttpConfig
--- timeout: 15
--- config
    location = /a {
        content_by_lua_block {
            local globals = require("zedcup").globals()

            local c = require("resty.consul"):new({
                host = TEST_CONSUL_HOST,
                port = TEST_CONSUL_port,
            })

            -- Clear up before running test
            c:delete_key(globals.prefix, {recurse = true})

            local watcher = require("zedcup.worker.watcher")

            -- Override the cache set/delete function so we can inspect which keys were deleted
            local real_delete = globals.cache.delete
            local deleted = {}
            globals.cache.delete = function(self, key)
                table.insert(deleted, key)
                return real_delete(globals.cache, key)
            end

            local set = {}
            local real_set = globals.cache.set
            globals.cache.set = function(self, key, ...)
                table.insert(set, key)
                return real_set(globals.cache, key, ...)
            end

            local dict = globals.dicts.cache
            ngx.say("dict idx: ", dict:get("config_index"))

            -- Run watcher, no config
            local ok = watcher._config_watcher()
            assert(ok == false, "First run == false")

            local res, err = c:get_key(globals.prefix.."/config/.placeholder")
            if not res then error(err) end
            ngx.say("placeholder: ",res.status)
            ngx.say("dict idx: ", dict:get("config_index"))


            -- Create some dummy keys
            c:put_key(globals.prefix.."/config/consul_wait_time", 1)
            c:put_key(globals.prefix.."/config/test/key1", "foo")
            c:put_key(globals.prefix.."/config/test/key2", "foo")
            c:put_key(globals.prefix.."/config/test/key3/key4", "foo")


ngx.log(ngx.DEBUG, "########################################################")
            -- Run watcher
            local ok = watcher._config_watcher()
            ngx.say("1st: ", ok, " ", #deleted)
            for _, v in ipairs(deleted) do ngx.say("del: ", v) end
            for _, v in ipairs(set) do ngx.say("set: ", v) end
            ngx.say("dict idx: ", (dict:get("config_index") ~= nil))

ngx.log(ngx.DEBUG, "########################################################")
            -- Re-Run watcher
            deleted, set = {}, {}
            local ok = watcher._config_watcher()
            ngx.say("2nd: ", ok, " ", #deleted)
            for _, v in ipairs(deleted) do ngx.say("del: ", v) end
            for _, v in ipairs(set) do ngx.say("set: ", v) end
ngx.log(ngx.DEBUG, "########################################################")

            -- Modify a key
            c:put_key(globals.prefix.."/config/test/key1", "bar")

ngx.log(ngx.DEBUG, "########################################################")
            -- Re-Run watcher
            deleted, set = {}, {}
            local ok = watcher._config_watcher()
            ngx.say("3rd: ", ok, " ", #deleted)
            for _, v in ipairs(deleted) do ngx.say("del: ", v) end
            for _, v in ipairs(set) do ngx.say("set: ", v) end
ngx.log(ngx.DEBUG, "########################################################")

            -- Remove a key
            c:delete_key(globals.prefix.."/config/test/key3/key4")

ngx.log(ngx.DEBUG, "########################################################")
            -- Re-Run watcher
            deleted, set = {}, {}
            local ok = watcher._config_watcher()
            ngx.say("4th: ", ok, " ", #deleted)
            for _, v in ipairs(deleted) do ngx.say("del: ", v) end
            for _, v in ipairs(set) do ngx.say("set: ", v) end


        }
    }
--- request
GET /a
--- response_body
dict idx: nil
placeholder: 200
dict idx: nil
1st: true 1
del: config
dict idx: true
2nd: nil 0
3rd: true 1
del: config
4th: true 1
del: config
--- no_error_log
[error]
[warn]
