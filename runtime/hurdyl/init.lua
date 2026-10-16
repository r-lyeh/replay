local _hurdytemp0
local path = (...):gsub(".init$", "") .. '.';
local M = require(path .. "main");
require(path .. "parser");
require(path .. "resolver");
require(path .. "transpiler");
require(path .. "ast");
_hurdytemp0 = M
local parse = _hurdytemp0.parse
local resolve = _hurdytemp0.resolve
local compile = _hurdytemp0.compile
local ast = _hurdytemp0.ast
local errorMessage = _hurdytemp0.errorMessage
local LuaTarget = _hurdytemp0.LuaTarget
_hurdytemp0 = nil
local hurdy = {
  _VERSION = M._VERSION,
  path = "./?.hurdy;./?/init.hurdy"
};
local errorWrap;
errorWrap = function(f, chunkName, ...)
  local status, a, b = pcall(f, ...);
  if not status then
    error(errorMessage(a, chunkName));
  end
  do return a, b end
end;
local _compile;
_compile = function(source, target)
  local statements = parse(source, target);
  resolve(statements);
  do return compile(statements) end
end;
local _generate_AST;
_generate_AST = function(source, useResolver)
  local statements = parse(source, "latest");
  resolve(statements, useResolver);
  do return ast(statements) end
end;
hurdy.compile = function(source, chunkName, target)
  if chunkName == nil then chunkName = "" end
  if target == nil then target = "latest" end
  if not LuaTarget[ target ] then
    error(string.format("Invalid target '%q'", target));
  end
  do return errorWrap(_compile, chunkName, source, target) end
end;
hurdy.generate_AST = function(source, useResolver)
  if useResolver == nil then useResolver = true end
  do return errorWrap(_generate_AST, nil, source, useResolver) end
end;
local luaTarget;
local load = load;
do
  local major, minor = string.match(_VERSION, "^Lua (%d+).(%d+)$");
  major, minor = tonumber(major), tonumber(minor);
  if major >= 5 and minor >= 3 then
    luaTarget = "5.3";
  elseif major == 5 and minor == 2 then
    luaTarget = "5.2";
  elseif major == 5 and minor == 1 then
    load = loadstring;
    luaTarget = loadstring("::test::") and "jit" or "5.1";
  else
    error("Only Lua 5.1+ is supported.");
  end
end
local lineMaps = {};
hurdy.loadstring = function(str, chunkName)
  local lua, lineMap = hurdy.compile(str, chunkName, luaTarget);
  local chunk, err = load(lua, chunkName);
  if chunk then
    if chunkName then
      lineMaps[ chunkName ] = lineMap;
    end
    do return chunk end
  else
    error(err);
  end
end;
hurdy.loadfile = function(filename)
  local f = assert(io.open(filename));
  local data = f:read("*a");
  f:close();
  do return hurdy.loadstring(data, "@" .. filename) end
end;
local searchpath = package.searchpath or function(name, path)
  local paths = {
    ""
  };
  name = name:gsub("%.", "/");
  for p in path:gmatch("[^;]+") do
    local fPath = p:gsub("?", name);
    local f = io.open(fPath);
    if f then
      f:close();
      do return fPath end
    end
    paths[ #paths + 1 ] = string.format("\tno file '%s'", fPath);
  end
  do return nil, table.concat(paths, "\n") end
end;
hurdy.searcher = function(name)
  local filename, err = searchpath(name, hurdy.path);
  do return filename and hurdy.loadfile(filename) or err end
end;
hurdy.singleErrHandler = function(msg)
  local level = 2;
  local info, _, b;
  while true do
    info = debug.getinfo(level, "Sl");
    if type(info) ~= "table" then
      do return msg end
    end
    local beginning = string.format("%s:%d:", info.short_src, info.currentline);
    _, b = msg:find(beginning, 1, true);
    if b then
      do break end;
    end
    level = level + 1;
  end
  local lineMap = lineMaps[ info.source ];
  if not lineMap then
    do return msg end
  end
  do return string.format("%s:%s%s", info.short_src, lineMap[ info.currentline ], msg:sub(b)) end
end;
local lastlevel;
lastlevel = function()
  local level = 1;
  while true do
    if not debug.getinfo(level, "") then
      do break end;
    end
    level = level + (1);
  end
  do return level end
end;
hurdy.tracebackErrHandler = function(msg, level)
  if level == nil then level = 2 end
  local t;
  if msg == nil then
    t = {
      "stack traceback:"
    };
  else
    t = {
      hurdy.singleErrHandler(msg),
      "\nstack traceback:"
    };
  end
  local last = lastlevel();
  local info;
  local limit2show = last - level > 21 and 10 or -1;
  while true do
    info = debug.getinfo(level, "Sln");
    if not info then
      do break end;
    end
    if limit2show == 0 then
      local n = last - level - 10;
      t[ #t + 1 ] = string.format("\n\t...\t(skipping %d levels)", n);
      level = level + (n);
    else
      local lineMap;
      if info.currentline <= 0 then
        t[ #t + 1 ] = string.format("\n\t%s: in ", info.short_src);
      else
        lineMap = lineMaps[ info.source ];
        local line = lineMap and lineMap[ info.currentline ] or info.currentline;
        t[ #t + 1 ] = string.format("\n\t%s:%s: in ", info.short_src, line);
      end
      if info.what == "C" then
        t[ #t + 1 ] = string.format("function '%s'", info.name);
      elseif info.what == "Lua" then
        if info.name then
          t[ #t + 1 ] = string.format("function '%s'", info.name);
        else
          local line = lineMap and lineMap[ info.linedefined ] or info.linedefined;
          t[ #t + 1 ] = string.format("function <%s:%d>", info.short_src, line);
        end
      else
        t[ #t + 1 ] = "main chunk";
      end
      if info.istailcall then
        t[ #t + 1 ] = "\n\t(...tail calls...)";
      end
      level = level + (1);
    end
    limit2show = limit2show - (1);
  end
  do return table.concat(t) end
end;
do return hurdy end
