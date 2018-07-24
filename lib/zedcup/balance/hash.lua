--luacheck: ignore
-- TODO: this...
local ngx_log = ngx.log
local ngx_DEBUG = ngx.DEBUG

local zedcup  = require("zedcup")
local GLOBALS = zedcup.globals()
local DEBUG =  GLOBALS.DEBUG

--local utils = require("zedcup.utils")

local _M = {
    _VERSION = "0.0.1",
}


return _M
