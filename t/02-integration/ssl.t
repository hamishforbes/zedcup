# vim:set ft= ts=4 sw=4 et:
use Test::Nginx::Socket 'no_plan';
use Cwd qw(cwd);

my $pwd = cwd();

$ENV{TEST_CONSUL_HOST}   ||= "127.0.0.1";
$ENV{TEST_CONSUL_PORT}   ||= "8500";
$ENV{TEST_NGINX_PORT}    ||= 1984;
$ENV{TEST_ZEDCUP_PREFIX} ||= "zedcup_test_suite";

$ENV{TEST_NGINX_HTML_DIR} ||= html_dir();
$ENV{TEST_NGINX_SOCKET_DIR} ||= $ENV{TEST_NGINX_HTML_DIR};
our $TEST_NGINX_SOCKET_DIR = $ENV{TEST_NGINX_SOCKET_DIR};

no_diff();
no_long_string();
no_root_location();

sub read_file {
    my $infile = shift;
    open my $in, $infile
        or die "cannot open $infile for reading: $!";
    my $cert = do { local $/; <$in> };
    close $in;
    $cert;
}

our $RootCACert = read_file("t/cert/rootCA.pem");
our $LocalCert = read_file("t/cert/localhost.crt");
our $LocalKey = read_file("t/cert/localhost.key");
our $ExampleCert = read_file("t/cert/example.com.crt");
our $ExampleKey = read_file("t/cert/example.com.key");

our $HttpConfig = qq{
    lua_package_path "$pwd/lib/?.lua;;";
    error_log logs/error.log debug;

    lua_shared_dict zedcup_cache 1m;
    lua_shared_dict zedcup_locks 1m;
    lua_shared_dict zedcup_ipc 1m;
    lua_socket_log_errors off;

    lua_ssl_verify_depth 5;
    lua_ssl_trusted_certificate "../html/rootca.pem";
    ssl_certificate "../html/localhost.crt";
    ssl_certificate_key "../html/localhost.key";


    init_by_lua_block {
        require("resty.core")

        local zedcup = require("zedcup")
        zedcup._debug(true)

        TEST_CONSUL_PORT = $ENV{TEST_CONSUL_PORT}
        TEST_CONSUL_HOST = "$ENV{TEST_CONSUL_HOST}"
        TEST_NGINX_PORT  = $ENV{TEST_NGINX_PORT}
        TEST_ZEDCUP_PREFIX = "$ENV{TEST_ZEDCUP_PREFIX}"
        TEST_NGINX_SOCKET_DIR  = "$ENV{TEST_NGINX_SOCKET_DIR}"
        TEST_NGINX_SSL_SOCK = "unix:"..TEST_NGINX_SOCKET_DIR.."/nginx-ssl.sock"

        zedcup.init({
            consul = {
                host = TEST_CONSUL_HOST,
                port = TEST_CONSUL_PORT,
            },
            prefix = TEST_ZEDCUP_PREFIX
        })

        DEFAULT_CONF = {
            ssl = true,
            pools = {
                {
                    name = "primary",
                    timeout = 100,
                    healthcheck = {
                        status_codes = {"50x"},
                        path = "/_healthcheck",
                        headers = {
                            Host = "www.example.com"
                        },
                        ssl = {
                            sni_name = "localhost"
                        }
                    },
                    hosts = {
                        { name = "web01", host = TEST_NGINX_SSL_SOCK },
                        {
                            name = "web02", host = TEST_NGINX_SSL_SOCK,
                            healthcheck = {
                                status_codes = {"50x"},
                                path = "/_healthcheck",
                                headers = {
                                    Host = "www.foo.com"
                                },
                                ssl = {
                                    verify = true,
                                    sni_name = "www.foo.com"
                                }
                            },
                        }
                    }
                },
                {
                    name = "secondary",
                    hosts = {
                        {
                            name = "dr01", host = TEST_NGINX_SSL_SOCK,
                            healthcheck = {
                                status_codes = {"50x"},
                                path = "/_healthcheck",
                                headers = {
                                    Host = "www.foo.com"
                                },
                                ssl = {
                                    verify = false,
                                    sni_name = "www.foo.com"
                                }
                            },
                        }
                    }
                },
            }
        }

    }

    init_worker_by_lua_block {
        --require("zedcup").run_workers()
    }

};

run_tests();

__DATA__
=== TEST 0: bootstrap config
--- http_config eval: $::HttpConfig
--- config
    location = /a {
        content_by_lua_block {
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
            ngx.say("OK")
        }
    }
--- user_files eval
">>> rootca.pem
$::RootCACert
>>> localhost.key
$::LocalKey
>>> localhost.crt
$::LocalCert
>>> example.com.key
$::ExampleKey
>>> example.com.crt
$::ExampleCert"
--- request
GET /a
--- response_body
OK


=== TEST 1: Basic SSL
--- http_config eval: $::HttpConfig
--- config
    listen unix:$TEST_NGINX_SOCKET_DIR/nginx-ssl.sock ssl;

    location = /a {
        content_by_lua_block {
            local handler = require("zedcup").create_handler("test")

            local connected_host
            assert(handler:bind("host_connect", function(data)
                connected_host = data.pool.name.."/"..data.host.name
            end), "Bind failed")

            local res, err = handler:request({ path = "/test", headers = {Host = "www.example.com" }})
            assert(res, "Res is nil: "..tostring(err) )

            local body = res:read_body()
            ngx.say(connected_host)

            ngx.say(res.status)
            ngx.print(body)

        }
    }

    location /test {
        content_by_lua_block {
            ngx.say("TEST OK ", ngx.var.scheme)
        }
    }
    location /_healthcheck {
        content_by_lua_block {
            ngx.say("HEALTHCHECK OK ", ngx.var.scheme)
        }
    }
--- user_files eval
">>> rootca.pem
$::RootCACert
>>> localhost.key
$::LocalKey
>>> localhost.crt
$::LocalCert"
--- request eval
["GET /a", "GET /a"]
--- response_body eval
[
"primary/web01
200
TEST OK https
",
"primary/web02
200
TEST OK https
",
]
--- no_error_log
[error]
[warn]


=== TEST 2: SSL verification
--- http_config eval: $::HttpConfig
--- config
    listen unix:$TEST_NGINX_SOCKET_DIR/nginx-ssl.sock ssl;

    ssl_certificate_by_lua_block {
        ngx.log(ngx.DEBUG, "sni_name ", require("ngx.ssl").server_name() )
    }

    location = /configure {
        content_by_lua_block {
            local args = ngx.req.get_uri_args()
            local verify = tostring((args.verify == "true"))
            local sni_name = args.sni_name or "locahost"

            local conf = require("zedcup.utils").tbl_copy(DEFAULT_CONF)
            conf.ssl = {
                sni_name = sni_name,
                verify = verify
            }
            local ok, err = require("zedcup").configure_instance("test", conf)
            if not ok then error(err) end
            require("zedcup").globals().cache:purge() -- Don't want to wait for the watcher here
            ngx.print("OK")
        }
    }

    location = /a {
        content_by_lua_block {
            require("zedcup").globals().cache:update()

            local handler = require("zedcup").create_handler("test")

            local connected_host
            assert(handler:bind("host_connect", function(data)
                connected_host = data.pool.name.."/"..data.host.name
            end), "Bind failed")

            local errs = {}
            assert(handler:bind("host_connect_error", function(data)
                table.insert(errs, data.pool.name.."/"..data.host.name..": "..tostring(err))
            end), "Bind failed")

            local res, err = handler:request({ path = "/test", headers = {Host = "www.example.com" }})
            if res then
                ngx.print(res:read_body())
            else
                ngx.print(err)
            end

            for _, err in ipairs(errs) do
                ngx.log(ngx.DEBUG, err)
            end
        }
    }

    location /test {
        content_by_lua_block {
            ngx.print("TEST OK ", ngx.var.scheme)
        }
    }
    location /_healthcheck {
        content_by_lua_block {
            ngx.print("HEALTHCHECK OK ", ngx.var.scheme)
        }
    }
--- user_files eval
">>> rootca.pem
$::RootCACert
>>> localhost.key
$::LocalKey
>>> localhost.crt
$::LocalCert"
--- request eval
[
    "GET /configure?verify=true&sni_name=www.google.com", "GET /a",
    "GET /configure?verify=false&sni_name=www.google.com", "GET /a",
    "GET /configure?verify=false&sni_name=www.example.com", "GET /a",
    "GET /configure?verify=true&sni_name=www.example.com", "GET /a",
    "GET /configure?verify=true&sni_name=localhost", "GET /a",
]
--- response_body eval
[
"OK", "No available upstream hosts",
"OK", "TEST OK https",
"OK", "TEST OK https",
"OK", "No available upstream hosts",
"OK", "TEST OK https",
]


=== TEST 3: SSL healthchecks
--- http_config eval: $::HttpConfig
--- config
    listen unix:$TEST_NGINX_SOCKET_DIR/nginx-ssl.sock ssl;

    ssl_certificate_by_lua_block {
        ngx.log(ngx.DEBUG, "sni_name ", require("ngx.ssl").server_name() )
    }

    location = /a {
        content_by_lua_block {
            local zedcup = require("zedcup")
            local globals = zedcup.globals()

            local c = require("resty.consul"):new({
                host = TEST_CONSUL_HOST,
                port = TEST_CONSUL_port,
            })

            -- Clear up before running test
            c:delete_key(globals.prefix, {recurse = true})

            -- Configure the instances
            local ok, err = zedcup.configure_instance("test", DEFAULT_CONF)
            if not ok then ngx.say(err) end

            -- bind to events
            local req_err = {}
            local ok, err = zedcup.bind("host_request_error", function(instance, data)
                ngx.log(ngx.DEBUG, "REQ ", instance, ": ", require("cjson").encode(data) )
                table.insert(req_err, instance..":"..data.host._pool.name.."/"..data.host.name.." : "..data.err)
            end)
            if err then error(err) end

            local conn_err = {}
            local ok, err = zedcup.bind("host_connect_error", function(instance, data)
                ngx.log(ngx.DEBUG, "CONN ", instance, ": ", require("cjson").encode(data) )
                table.insert(conn_err, instance..":"..data.host._pool.name.."/"..data.host.name.." : "..data.err)
            end)
            if err then error(err) end

            local healthcheck = require("zedcup.worker.healthcheck")._healthcheck

            local ok, err = healthcheck(false)
            if not ok then
                ngx.say(err)
            end

            table.sort(req_err)
            table.sort(conn_err)

            for _, err in pairs(req_err) do ngx.say("Request err: ", err) end
            for _, err in pairs(conn_err) do ngx.say("Connect err: ", err) end

            ngx.say("OK")
        }
    }

    location /_healthcheck {
        content_by_lua_block {
            ngx.say("HEALTHCHECK OK ", ngx.var.scheme)
            ngx.log(ngx.DEBUG, "HEALTHCHECK OK ", ngx.var.scheme)
        }
    }
--- user_files eval
">>> rootca.pem
$::RootCACert
>>> localhost.key
$::LocalKey
>>> localhost.crt
$::LocalCert
>>> example.com.key
$::ExampleKey
>>> example.com.crt
$::ExampleCert"
--- request
GET /a
--- response_body
Connect err: test:primary/web02 : certificate host mismatch
OK
--- no_error_log
[error]
[warn]
--- error_log
HEALTHCHECK OK http
