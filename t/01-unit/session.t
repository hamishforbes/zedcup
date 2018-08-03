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

        -- override the config function
        zedcup.get_config = function()
            return {
                session_renew_interval = 10,
                session_ttl = 30,
                worker_lock_ttl = 30,
                }
            end
    }

};

run_tests();

__DATA__
=== TEST 1: create / get / register / destroy
--- http_config eval: $::HttpConfig
--- config
    location = /a {
        content_by_lua_block {
            local session = require("zedcup.session")
            local globals = require("zedcup").globals()

            local c = require("resty.consul"):new({
                host = TEST_CONSUL_HOST,
                port = TEST_CONSUL_port,
            })

            -- Clear up before running test
            c:delete_key(globals.prefix, {recurse = true})

            -- Get / Create the session
            local id, err = session.get()
            ngx.log(ngx.DEBUG, id)
            if err then
                error(err)
            end
            ngx.say("OK")

            -- Check session info matches
            local res, err = c:get("/session/info/" .. id)
            ngx.log(ngx.DEBUG, require("cjson").encode(res.body) )

            ngx.say("Behaviour: ", res.body[1].Behavior )
            ngx.say("TTL: ", res.body[1].TTL )
            ngx.say("Name: ", res.body[1].Name == "zedcup: "..ngx.worker.pid() )


            -- Get the session again
            local id2, err = session.get()
            ngx.log(ngx.DEBUG, id2)
            if err then
                error(err)
            end

            assert(id2 == id, "IDs don't match")

            -- Check registry
            local res, err = c:get_key(globals.prefix.."/registry", { recurse = true })
            ngx.log(ngx.DEBUG, require("cjson").encode(res.body) )

            ngx.say("Registry count: ", #res.body)
            assert(res.body[1].Session == id, "Registry doesn't match")

            local key = string.sub(res.body[1].Key, #(globals.prefix.."/registry")+2, -1)
            ngx.log(ngx.DEBUG, key)
            assert(key == id, "Incorrect registry key doesn't match")


            -- Destroy session
            local ok, err = session.destroy()
            ngx.say(ok)

            -- Check info again
            local res, err = c:get("/session/info/" .. id)
            ngx.log(ngx.DEBUG, require("cjson").encode(res.body) )
            assert(#res.body == 0, "Session still exists!")

            -- Check registry has been cleaned
            local res, err = c:get_key(globals.prefix.."/registry/"..id)
            ngx.log(ngx.DEBUG, require("cjson").encode(res.body) )
            ngx.say(res.status)

        }
    }
--- request
GET /a
--- response_body
OK
Behaviour: delete
TTL: 30s
Name: true
Registry count: 1
true
404
--- no_error_log
[error]
[warn]

=== TEST 2: renew
--- http_config eval: $::HttpConfig
--- config
    location = /a {
        content_by_lua_block {
        require("zedcup").config = function()
            return {
                session_renew_interval = 10,
                session_ttl = 11,
                }
            end
            local session = require("zedcup.session")
            local globals = require("zedcup").globals()

            local c = require("resty.consul"):new({
                host = TEST_CONSUL_HOST,
                port = TEST_CONSUL_port,
            })

            -- Clear up before running test
            c:delete_key(globals.prefix, {recurse = true})

            -- Get / Create the session
            local id, err = session.get()
            ngx.log(ngx.DEBUG, id)
            if err then
                error(err)
            end

            -- Should not renew
            local ok, err = session.renew()
            ngx.say(ok)
            ngx.say(err)

            ngx.sleep(1) -- Should be inside the renew window now

            local ok, err = session.renew()
            ngx.say(ok)
            ngx.say(err)

            local res, err = c:get("/session/info/" .. id)
            ngx.log(ngx.DEBUG, res.status, ": ", require("cjson").encode(res.body) )
            ngx.say("Info: ", #res.body)

            ngx.sleep(25) -- bit flakey, consul session expiry isn't exact

            -- Check info again
            local res, err = c:get("/session/info/" .. id)
            ngx.log(ngx.DEBUG, res.status, ": ", require("cjson").encode(res.body) )
            ngx.say("Info: ", #res.body)

            -- Renew an expired session
            local ok, err = session.renew()
            ngx.say(ok)
            ngx.say(err)


            local id2, err = session.get()
            ngx.log(ngx.DEBUG, id2)
            if err then
                error(err)
            end
            assert(id ~= id2, "Did not create a new session!")
            ngx.say("OK")

        }
    }
--- timeout: 30
--- request
GET /a
--- response_body
nil
nil
true
nil
Info: 1
Info: 0
false
nil
OK
--- no_error_log
[error]
[warn]


=== TEST 3: worker
--- http_config eval: $::HttpConfig
--- config
    location = /a {
        content_by_lua_block {
            require("zedcup").get_config = function()
                return {
                    session_renew_interval = 1,
                    session_ttl = 15,
                    }
            end

            local session = require("zedcup.session")
            local globals = require("zedcup").globals()

            local worker = require("zedcup.worker.session")

            local c = require("resty.consul"):new({
                host = TEST_CONSUL_HOST,
                port = TEST_CONSUL_port,
            })

            -- Clear up before running test
            c:delete_key(globals.prefix, {recurse = true})

            local id, err = session.get()
            ngx.log(ngx.DEBUG, id)

            -- Start worker
            local ok, err = worker.run()
            ngx.log(ngx.DEBUG, ok, ": ", err)
            assert(ok, "Worker did not start")

            ngx.sleep(25)

            local id2, err = session.get()
            ngx.log(ngx.DEBUG, id2)
            if err then
                error(err)
            end
            assert(id == id2, "Session did not renew")
            ngx.say("OK")
        }
    }
--- timeout: 30
--- request
GET /a
--- response_body
OK
--- no_error_log
[error]
[warn]
