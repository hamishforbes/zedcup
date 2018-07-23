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
    }
};

run_tests();

__DATA__
=== TEST 1: tbl_copy
--- http_config eval: $::HttpConfig
--- config
    location = /a {
        content_by_lua_block {

        }
    }
--- request
GET /a
--- response_body

--- no_error_log
[error]
[warn]

=== TEST 2: tbl_copy_merge_defaults
--- http_config eval: $::HttpConfig
--- config
    location = /a {
        content_by_lua_block {

        }
    }
--- request
GET /a
--- response_body

--- no_error_log
[error]
[warn]

=== TEST 3: str_split
--- http_config eval: $::HttpConfig
--- config
    location = /a {
        content_by_lua_block {

        }
    }
--- request
GET /a
--- response_body

--- no_error_log
[error]
[warn]

=== TEST 4: entries2table
--- http_config eval: $::HttpConfig
--- config
    location = /a {
        content_by_lua_block {

        }
    }
--- request
GET /a
--- response_body

--- no_error_log
[error]
[warn]

=== TEST 5: error_delay
--- http_config eval: $::HttpConfig
--- config
    location = /a {
        content_by_lua_block {

        }
    }
--- request
GET /a
--- response_body

--- no_error_log
[error]
[warn]

=== TEST 1: table2txn
--- http_config eval: $::HttpConfig
--- config
    location = /a {
        content_by_lua_block {

        }
    }
--- request
GET /a
--- response_body

--- no_error_log
[error]
[warn]
