local _hurdytemp0
local path = (...):gsub("[^%.]*$", "");
local M = require(path .. "main");
M.LuaTarget = {
  [ "5.1" ] = 1,
  [ "jit" ] = 2,
  [ "5.2" ] = 3,
  [ "5.3" ] = 4,
  [ "latest" ] = 5
};
