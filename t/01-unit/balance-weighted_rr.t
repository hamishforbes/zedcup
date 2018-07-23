# vim:set ft= ts=4 sw=4 et:
use Test::Nginx::Socket 'no_plan';
use Cwd qw(cwd);

my $pwd = cwd();

no_diff();
no_long_string();

our $HttpConfig = qq{
    lua_package_path "$pwd/lib/?.lua;;";
    error_log logs/error.log debug;

    init_by_lua_block {
        require("resty.core")

        local zedcup = require("zedcup")
        zedcup._debug(true)

        MOCK_POOL = {
            _idx = 1,
            hosts = {
                { ["_idx"] = 1, weight = 10, name = "host01", up = true },
                { ["_idx"] = 2, weight = 20, name = "host02", up = true },
                { ["_idx"] = 3, weight = 30, name = "host03", up = true },
            }
        }

        MOCK_HANDLER = {
            ctx = {
                failed = {
                    {},
                }
            },
            op_data = {},
        }
    }

};

run_tests();

__DATA__
=== TEST 1: select_host
--- http_config eval: $::HttpConfig
--- config
    location = /a {
        content_by_lua_block {
            local tbl_copy = require("zedcup.utils").tbl_copy

            local pool = tbl_copy(MOCK_POOL)
            local handler = tbl_copy(MOCK_HANDLER)

            pool.hosts = {
                { ["_idx"] = 1, weight = 10, name = "host01", up = true },
                { ["_idx"] = 2, weight = 10, name = "host02", up = true },
                { ["_idx"] = 3, weight = 10, name = "host03", up = true },
            }

            local balancer = require("zedcup.balance.weighted_rr")

            for i=1, 10, 1 do
                local host, err = balancer.select_host(handler, pool)
                if err then error(err) end
                if not host then  error("nil host") end

                ngx.say(host.name)
            end

        }
    }
--- request
GET /a
--- response_body
host01
host02
host03
host01
host02
host03
host01
host02
host03
host01
--- no_error_log
[error]
[warn]

=== TEST 2: select_host, weightings
--- http_config eval: $::HttpConfig
--- config
    location = /a {
        content_by_lua_block {
            local tbl_copy = require("zedcup.utils").tbl_copy

            local pool = tbl_copy(MOCK_POOL)
            local handler = tbl_copy(MOCK_HANDLER)

            local balancer = require("zedcup.balance.weighted_rr")

            for i=1, 10, 1 do
                local host, err = balancer.select_host(handler, pool)
                if err then error(err) end
                if not host then  error("nil host") end

                ngx.say(host.name)
            end

        }
    }
--- request
GET /a
--- response_body
host02
host03
host01
host02
host03
host02
host03
host01
host02
host03
--- no_error_log
[error]
[warn]


=== TEST 3: select_host, down hosts are skipped
--- http_config eval: $::HttpConfig
--- config
    location = /a {
        content_by_lua_block {
            local tbl_copy = require("zedcup.utils").tbl_copy

            local pool = tbl_copy(MOCK_POOL)
            local handler = tbl_copy(MOCK_HANDLER)

            pool.hosts = {
                { ["_idx"] = 1, weight = 10, name = "host01", up = true },
                { ["_idx"] = 2, weight = 10, name = "host02", up = false },
                { ["_idx"] = 3, weight = 10, name = "host03", up = true },
            }

            local balancer = require("zedcup.balance.weighted_rr")

            for i=1, 10, 1 do
                local host, err = balancer.select_host(handler, pool)
                if err then error(err) end
                if not host then  error("nil host") end

                ngx.say(host.name)
            end

        }
    }
--- request
GET /a
--- response_body
host01
host03
host01
host03
host01
host03
host01
host03
host01
host03
--- no_error_log
[error]
[warn]

=== TEST 4: select_host, single host
--- http_config eval: $::HttpConfig
--- config
    location = /a {
        content_by_lua_block {
            local tbl_copy = require("zedcup.utils").tbl_copy

            local pool = tbl_copy(MOCK_POOL)
            local handler = tbl_copy(MOCK_HANDLER)

            pool.hosts = {
                { ["_idx"] = 1, weight = 10, name = "host01", up = true },
            }

            local balancer = require("zedcup.balance.weighted_rr")

            for i=1, 10, 1 do
                local host, err = balancer.select_host(handler, pool)
                if err then error(err) end
                if not host then  error("nil host") end

                ngx.say(host.name)
            end

        }
    }
--- request
GET /a
--- response_body
host01
host01
host01
host01
host01
host01
host01
host01
host01
host01
--- no_error_log
[error]
[warn]

=== TEST 5: select_host, failed hosts are skipped
--- http_config eval: $::HttpConfig
--- config
    location = /a {
        content_by_lua_block {
            local tbl_copy = require("zedcup.utils").tbl_copy

            local pool = tbl_copy(MOCK_POOL)
            local handler = tbl_copy(MOCK_HANDLER)

            pool.hosts = {
                { ["_idx"] = 1, weight = 10, name = "host01", up = true },
                { ["_idx"] = 2, weight = 10, name = "host02", up = true },
                { ["_idx"] = 3, weight = 10, name = "host03", up = true },
            }

            handler.ctx.failed = {
                {
                    [3] = true,
                }
            }

            local balancer = require("zedcup.balance.weighted_rr")

            for i=1, 10, 1 do
                local host, err = balancer.select_host(handler, pool)
                if err then error(err) end
                if not host then  error("nil host") end

                ngx.say(host.name)
            end

        }
    }
--- request
GET /a
--- response_body
host01
host02
host01
host02
host01
host02
host01
host02
host01
host02
--- no_error_log
[error]
[warn]

=== TEST 6: select_host, all hosts down
--- http_config eval: $::HttpConfig
--- config
    location = /a {
        content_by_lua_block {
            local tbl_copy = require("zedcup.utils").tbl_copy

            local pool = tbl_copy(MOCK_POOL)
            local handler = tbl_copy(MOCK_HANDLER)

            pool.hosts = {
                { ["_idx"] = 1, weight = 10, name = "host01", up = false },
                { ["_idx"] = 2, weight = 10, name = "host02", up = false },
                { ["_idx"] = 3, weight = 10, name = "host03", up = false },
            }

            local balancer = require("zedcup.balance.weighted_rr")

            for i=1, 10, 1 do
                local host, err = balancer.select_host(handler, pool)
                if err then error(err) end
                if host then  error(" host selected") end

                ngx.say(host)
            end

        }
    }
--- request
GET /a
--- response_body
nil
nil
nil
nil
nil
nil
nil
nil
nil
nil
--- no_error_log
[error]
[warn]

=== TEST 7: select_host, all hosts failed
--- http_config eval: $::HttpConfig
--- config
    location = /a {
        content_by_lua_block {
            local tbl_copy = require("zedcup.utils").tbl_copy

            local pool = tbl_copy(MOCK_POOL)
            local handler = tbl_copy(MOCK_HANDLER)

            pool.hosts = {
                { ["_idx"] = 1, weight = 10, name = "host01", up = true },
                { ["_idx"] = 2, weight = 10, name = "host02", up = true },
                { ["_idx"] = 3, weight = 10, name = "host03", up = true },
            }

            handler.ctx.failed = {
                {
                    true,
                    true,
                    true,
                }
            }

            local balancer = require("zedcup.balance.weighted_rr")

            for i=1, 10, 1 do
                local host, err = balancer.select_host(handler, pool)
                if err then error(err) end
                if host then  error(" host selected") end

                ngx.say(host)
            end

        }
    }
--- request
GET /a
--- response_body
nil
nil
nil
nil
nil
nil
nil
nil
nil
nil
--- no_error_log
[error]
[warn]

=== TEST 7: select_host, all hosts failed / down
--- http_config eval: $::HttpConfig
--- config
    location = /a {
        content_by_lua_block {
            local tbl_copy = require("zedcup.utils").tbl_copy

            local pool = tbl_copy(MOCK_POOL)
            local handler = tbl_copy(MOCK_HANDLER)

            pool.hosts = {
                { ["_idx"] = 1, weight = 10, name = "host01", up = false },
                { ["_idx"] = 2, weight = 10, name = "host02", up = true },
                { ["_idx"] = 3, weight = 10, name = "host03", up = true },
            }

            handler.ctx.failed = {
                {
                    [2] = true,
                    [3] = true,
                }
            }

            local balancer = require("zedcup.balance.weighted_rr")

            for i=1, 10, 1 do
                local host, err = balancer.select_host(handler, pool)
                if err then error(err) end
                if host then  error(" host selected") end

                ngx.say(host)
            end

        }
    }
--- request
GET /a
--- response_body
nil
nil
nil
nil
nil
nil
nil
nil
nil
nil
--- no_error_log
[error]
[warn]
