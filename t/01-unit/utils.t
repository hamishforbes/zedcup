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
location /t {
    content_by_lua_block {
        local tbl_copy = require("zedcup.utils").tbl_copy

        local t = {
            a = 1,
            b = 2,
            c = {
                x = "foo",
                y = false,
                z = {"bar", true, "baz"}
            }
        }

        local copy = tbl_copy(t)

        -- Values copied
        assert(t ~= copy, "copy should not equal t")
        assert(copy.a == 1, "copy.a should be 1")
        assert(type(copy.c) == "table", "copy.c should be a table")
        assert(copy.c ~= t.c, "copy.c should not equal t.c")
        assert(copy.c.x == "foo", "copy.c.x should be 'foo'")
        assert(copy.c.y == false, "copy.c.x should be false")
        assert(type(copy.c.z) == "table", "copy.c.z should be a table")
        assert(copy.c.z ~= t.c.z, "copy.z.a. should not equal t.c.z")
        assert(copy.c.z[1] == "bar", "copy.c.z[1] should be bar")
        assert(copy.c.z[2] == true, "copy.c.z[3] should be true")
        assert(copy.c.z[3] == "baz", "copy.c.z[1] should be baz")
    }
}
--- request
GET /t
--- no_error_log
[error]



=== TEST 2: table.copy_merge_defaults
--- http_config eval: $::HttpConfig
--- config
location /t {
    content_by_lua_block {
        local tbl_copy_merge_defaults = require("zedcup.utils").tbl_copy_merge_defaults

        local defaults = {
            a = 1,
            c = 3,
            d = {
                x = 10,
                z = 12,
            },
            e = {
                a = "foo",
                c = "bar",
            },
        }

        local t = {
            a = false,
            b = 2,
            e = {
                b = 2,
                d = "baz"
            },
        }

        local copy = tbl_copy_merge_defaults(t, defaults)

        -- Basic copy merge
        assert(copy ~= t, "copy should not equal t")
        assert(copy.a == false, "copy.a should be false")
        assert(copy.b == 2, "copy.b should be 2")
        assert(copy.c == 3, "copy.c should be 3")

        -- Child table in defaults is merged
        assert(copy.d ~= defaults.d, "copy.d should not equal defaults d")
        assert(copy.d.x == 10, "copy.d.x should be 10")
        assert(copy.d.z == 12, "copy.d.z should be 12")

        -- Child table in both is merged
        assert(copy.e ~= defaults.e, "copy.e should not equal defaults e")
        assert(copy.e.a == "foo", "copy.e.a should be foo")
        assert(copy.e.b == 2, "copy.e.b should be 2")
        assert(copy.e.c == "bar", "copy.e.c should be bar")
        assert(copy.e.d == "baz", "copy.e.d should be baz")
    }
}
--- request
GET /t
--- no_error_log
[error]


=== TEST 3: str_split
--- http_config eval: $::HttpConfig
--- config
location /t {
    content_by_lua_block {
        local str_split = require("zedcup.utils").str_split

        local str1 = "comma, separated, string, "
        local t = str_split(str1, ",")

        assert(#t == 4, "#t should be 4")
        assert(t[1] == "comma", "t[1] should be 'comma'")
        assert(t[2] == " separated", "t[2] should be ' separated'")
        assert(t[3] == " string", "t[3] should be ' string'")
        assert(t[4] == " ", "t[4] should be ' '")

        local t = str_split(str1, ", ")
        assert(#t == 3, "#t should be 3")
        assert(t[1] == "comma", "t[1] should be 'comma'")
        assert(t[2] == "separated", "t[2] should be ' separated'")
        assert(t[3] == "string", "t[3] should be ' string'")
    }
}
--- request
GET /t
--- no_error_log
[error]

=== TEST 4: entries2table
--- http_config eval: $::HttpConfig
--- config
    location = /a {
        content_by_lua_block {
            local entries2table = require("zedcup.utils").entries2table

            local entries = {
                {
                    LockIndex   = 0,
                    Key         = "/dummy/prefix/a/b/c",
                    Flags       = 0,
                    Value       = "a-b-c",
                    CreateIndex = 1,
                    ModifyIndex = 2,
                },
                {
                    LockIndex   = 0,
                    Key         = "/dummy/prefix/foo/bar",
                    Flags       = 10,
                    Value       = "foo-bar",
                    CreateIndex = 1,
                    ModifyIndex = 2,
                },
                {
                    LockIndex   = 0,
                    Key         = "/dummy/prefix/a/subkey",
                    Flags       = 0,
                    Value       = "a-subkey",
                    CreateIndex = 1,
                    ModifyIndex = 2,
                },
                {
                    LockIndex   = 0,
                    Key         = "/dummy/prefix/type/bool/t",
                    Flags       = 0,
                    Value       = "true",
                    CreateIndex = 1,
                    ModifyIndex = 2,
                },
                {
                    LockIndex   = 0,
                    Key         = "/dummy/prefix/type/bool/f",
                    Flags       = 0,
                    Value       = "false",
                    CreateIndex = 1,
                    ModifyIndex = 2,
                },
                {
                    LockIndex   = 0,
                    Key         = "/dummy/prefix/type/number",
                    Flags       = 0,
                    Value       = "1234",
                    CreateIndex = 1,
                    ModifyIndex = 2,
                },
                {
                    LockIndex   = 0,
                    Key         = "/dummy/prefix/array/1",
                    Flags       = 0,
                    Value       = "a-1",
                    CreateIndex = 1,
                    ModifyIndex = 2,
                },
                {
                    LockIndex   = 0,
                    Key         = "/dummy/prefix/array/3",
                    Flags       = 0,
                    Value       = "a-3",
                    CreateIndex = 1,
                    ModifyIndex = 2,
                },
                {
                    LockIndex   = 0,
                    Key         = "/dummy/prefix/array/2",
                    Flags       = 0,
                    Value       = "a-2",
                    CreateIndex = 1,
                    ModifyIndex = 2,
                },
            }

            local t = entries2table(entries, "/dummy/prefix/")
            ngx.log(ngx.DEBUG, require("cjson").encode(t))

            assert(t.a.b.c == "a-b-c", "a.b.c is 'a-b-c'")
            assert(t.foo.bar == "foo-bar", "foo.bar  is 'foo-bar'")
            assert(t.a.subkey == "a-subkey", "a.subkey is 'a-subkey'")
            assert(t.type.bool.t == true, "type.bool.t is boolean true")
            assert(t.type.bool.f == false, "type.bool.f is boolean false")
            assert(t.type.number == 1234, "a.type.number is numeric 1234")
            assert(#t.array == 3, "#array is 3")
            assert(t.array[1] == "a-1", "array[2] is a-2")
            assert(t.array[2] == "a-2", "array[1] is a-1")
            assert(t.array[3] == "a-3", "array[3] is a-3")

            -- No prefix
            local t = entries2table(entries)
            ngx.log(ngx.DEBUG, require("cjson").encode(t))

            assert(t.dummy.prefix.a.b.c == "a-b-c", "dummy.prefix.a.b.c is 'a-b-c'")

            -- Callback
            local t = entries2table(entries, "/dummy/prefix/", function(tbl, key, entry)
                tbl[key] = entry["Value"]

                if key == "bar" then
                    tbl["bar_flag"] = entry.Flags
                end
            end)
            ngx.log(ngx.DEBUG, require("cjson").encode(t))
            assert(t.a.b.c == "a-b-c", "a.b.c is 'a-b-c'")
            assert(t.foo.bar == "foo-bar", "foo.bar  is 'foo-bar'")
            assert(t.foo.bar_flag == 10, "bar_flag is 10")


            -- Conflicting entries
            local entries = {
                {
                    LockIndex   = 0,
                    Key         = "/dummy/prefix/a/b/c",
                    Flags       = 0,
                    Value       = "a-b-c",
                    CreateIndex = 1,
                    ModifyIndex = 2,
                },
                {
                    LockIndex   = 0,
                    Key         = "/dummy/prefix/a/b",
                    Flags       = 0,
                    Value       = "a-b",
                    CreateIndex = 1,
                    ModifyIndex = 2,
                },
            }

            local t = entries2table(entries, "/dummy/prefix/")
            ngx.log(ngx.DEBUG, require("cjson").encode(t))

            assert(t.a.b.c == "a-b-c", "a.b.c == 'a-b-c'")

            local entries = {
                {
                    LockIndex   = 0,
                    Key         = "/dummy/prefix/a/b",
                    Flags       = 0,
                    Value       = "a-b",
                    CreateIndex = 1,
                    ModifyIndex = 2,
                },
                {
                    LockIndex   = 0,
                    Key         = "/dummy/prefix/a/b/c",
                    Flags       = 0,
                    Value       = "a-b-c",
                    CreateIndex = 1,
                    ModifyIndex = 2,
                },

            }

            local t = entries2table(entries, "/dummy/prefix/")
            ngx.log(ngx.DEBUG, require("cjson").encode(t))

            assert(t.a.b == "a-b", "a.b == 'a-b'")

        }
    }
--- request
GET /a
--- error_log
Conflict /dummy/prefix/a/b has an existing value
Conflict /dummy/prefix/a/b/c has an existing value


=== TEST 5: table2txn
--- http_config eval: $::HttpConfig
--- config
    location = /a {
        content_by_lua_block {
            local table2txn = require("zedcup.utils").table2txn

            local t = {
                array = {"foo", "bar", "baz"},
                sub_t = {
                    a = 1,
                    b = "b",
                    c = "false"
                },
                a = "abcd",
                b = "1234",
            }

            local txn = {}
            table2txn("/dummy/prefix/", t, txn)
            ngx.log(ngx.DEBUG, require("cjson").encode(txn))

            assert(#txn == 8, "payload len")
            assert(txn[1].KV.Value == "1234" and txn[1].KV.Key == "/dummy/prefix/b", "txn[1]")
            assert(txn[2].KV.Value == "b" and txn[2].KV.Key == "/dummy/prefix/sub_t/b", "txn[2]")
            assert(txn[8].KV.Value == "baz" and txn[8].KV.Key == "/dummy/prefix/array/3", "txn[8]")

        }
    }
--- request
GET /a
--- response_body

--- no_error_log
[error]
[warn]


=== TEST 6: error_delay
--- http_config eval: $::HttpConfig
--- config
    location = /a {
        content_by_lua_block {
            local delay = require("zedcup.utils").error_delay

            assert( delay(1) == 2, "1 == 2")
            assert( delay(2) == 4, "2 == 4")
            assert( delay(3) == 8, "3 == 8")
            assert( delay(20) == 300, "20 == 300")
            assert( delay(0) == 1, "0 == 1")
            assert( delay() == 2, "nil == 2")
        }
    }
--- request
GET /a
--- response_body

--- no_error_log
[error]
[warn]

=== TEST 7: thread_map
--- http_config eval: $::HttpConfig
--- config
    location = /a {
        content_by_lua_block {
            local thread_map = require("zedcup.utils").thread_map

            local map = {
                "arg1",
                "arg2",
                "arg3"
            }

            local res2 = {}
            local func = function(arg, a, b)
                res2[arg] = {a, b}
                return "res_"..arg
            end

            local res = thread_map(map, func, "foo", "bar")

            for k,v in pairs(res2) do
                ngx.say(k, ": ", v[1], " ", v[2])
            end

            for k,v in pairs(res) do
                ngx.say(k, ": ", v)
            end

        }
    }
--- request
GET /a
--- response_body
arg2: foo bar
arg3: foo bar
arg1: foo bar
1: res_arg1
2: res_arg2
3: res_arg3
--- no_error_log
[error]
[warn]

=== TEST 9: array2hash
--- http_config eval: $::HttpConfig
--- config
    location = /a {
        content_by_lua_block {
            local array2hash = require("zedcup.utils").array2hash

            local array = {"foo", "bar", "baz"}
            local hash = array2hash(array)

            assert( hash.foo, "foo")
            assert( hash.bar, "foo")
            assert( hash.baz, "foo")
        }
    }
--- request
GET /a
--- response_body

--- no_error_log
[error]
[warn]
