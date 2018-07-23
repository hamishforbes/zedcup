local ngx_log = ngx.log
local ngx_DEBUG = ngx.DEBUG
local ngx_ERR = ngx.ERR
local ngx_INFO = ngx.INFO

local zedcup  = require("zedcup")
local GLOBALS = zedcup.globals()
local DEBUG =  GLOBALS.DEBUG

--local utils = require("zedcup.utils")

local _M = {
    _VERSION = "0.0.1",
}


return _M
