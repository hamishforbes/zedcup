# vim:set ft= ts=4 sw=4 et:
use Test::Nginx::Socket 'no_plan';
use Cwd qw(cwd);

my $pwd = cwd();

$ENV{TEST_CONSUL_HOST} ||= "127.0.0.1";
$ENV{TEST_CONSUL_PORT} ||= "8500";

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

        zedcup.init({
            consul = {
                host = TEST_CONSUL_HOST,
                port = TEST_CONSUL_PORT,
            }
        })

        -- override the config function
        zedcup.config = function()
            return {
                host_revive_interval = 10,
                cache_update_interval = 1,
                watcher_interval = 10,
                session_renew_interval = 10,
                session_ttl = 30,
                worker_lock_ttl = 30,
                consul_wait_time = 1,
            }
        end
    }

};

run_tests();

__DATA__
=== TEST 1: Instance watcher
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

            -- Clear up before running test
            c:delete_key(globals.prefix, {recurse = true})

            -- Create some dummy keys
            c:put_key(globals.prefix.."/instances/test/key1", "foo")
            c:put_key(globals.prefix.."/instances/test/key2", "foo")
            c:put_key(globals.prefix.."/instances/test/key2/key3", "foo")

            c:put_key(globals.prefix.."/instances/test2/key1", "foo")
            c:put_key(globals.prefix.."/instances/test2/key2", "foo")
            c:put_key(globals.prefix.."/instances/test2/key2/key3", "foo")

ngx.log(ngx.DEBUG, "########################################################")
            -- Run watcher
            local ok = watcher._instance_watcher()
            ngx.say("1st: ", ok, " ", #deleted)
            for _, v in ipairs(deleted) do ngx.say("del: ", v) end
            for _, v in ipairs(set) do ngx.say("set: ", v) end

ngx.log(ngx.DEBUG, "########################################################")
            -- Re-Run watcher
            deleted, set = {}, {}
            local ok = watcher._instance_watcher()
            ngx.say("2nd: ", ok, " ", #deleted)
            for _, v in ipairs(deleted) do ngx.say("del: ", v) end
            for _, v in ipairs(set) do ngx.say("set: ", v) end
ngx.log(ngx.DEBUG, "########################################################")

            -- Populate the index entry
            local handler, err = require("zedcup").create_handler("test")
            if err then error(err) end
            local config, err = handler:config()
            if err then error(err) end

            -- Modify uncached key
            c:put_key(globals.prefix.."/instances/test2/key2/key3", "foo")
            -- Add a new instance
            c:put_key(globals.prefix.."/instances/test3/bar", "foo")

ngx.log(ngx.DEBUG, "########################################################")
            -- Re-Run watcher
            deleted, set = {}, {}
            local ok = watcher._instance_watcher()
            ngx.say("3rd: ", ok, " ", #deleted)
            for _, v in ipairs(deleted) do ngx.say("del: ", v) end
            for _, v in ipairs(set) do ngx.say("set: ", v) end
ngx.log(ngx.DEBUG, "########################################################")

            -- Modify cached key
            c:put_key(globals.prefix.."/instances/test/foobar/baz", "foo")
            -- Remove a instance
            c:delete_key(globals.prefix.."/instances/test3/bar")

ngx.log(ngx.DEBUG, "########################################################")
            -- Re-Run watcher
            deleted, set = {}, {}
            local ok = watcher._instance_watcher()
            ngx.say("4th: ", ok, " ", #deleted)
            for _, v in ipairs(deleted) do ngx.say("del: ", v) end
            for _, v in ipairs(set) do ngx.say("set: ", v) end
ngx.log(ngx.DEBUG, "########################################################")
            -- Re-Run watcher
            deleted, set = {}, {}
            local ok = watcher._instance_watcher()
            ngx.say("5th: ", ok, " ", #deleted)
            for _, v in ipairs(deleted) do ngx.say("del: ", v) end
            for _, v in ipairs(set) do ngx.say("set: ", v) end
ngx.log(ngx.DEBUG, "########################################################")

           -- Modify uncached key
            c:put_key(globals.prefix.."/instances/test2/key2/key1", "foo")
ngx.log(ngx.DEBUG, "########################################################")
            -- Re-Run watcher
            deleted, set = {}, {}
            local ok = watcher._instance_watcher()
            ngx.say("6th: ", ok, " ", #deleted)
            for _, v in ipairs(deleted) do ngx.say("del: ", v) end
            for _, v in ipairs(set) do ngx.say("set: ", v) end
        }
    }
--- request
GET /a
--- response_body
1st: true 0
2nd: nil 0
3rd: true 0
set: instance_list
4th: true 1
del: test_config
set: instance_list
5th: nil 0
6th: true 0
--- no_error_log
[error]
[warn]
