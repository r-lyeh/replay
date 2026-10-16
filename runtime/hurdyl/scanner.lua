local _hurdytemp0
local path = (...):gsub("[^%.]*$", "");
local M = require(path .. "main");
require(path .. "error");
require(path .. "target");
_hurdytemp0 = M
local Error = _hurdytemp0.Error
local LuaTarget = _hurdytemp0.LuaTarget
_hurdytemp0 = nil
M.scanner = {};
local source, start, current, lineStart, line, target;
local isAtEnd, makeToken, makeError, advance, peek, peekNext, match, skipLineComment, SkipBlockComment, identifierType, shortString, longString, isDigit, isAlpha, isHex, number, identifier, isLuaReserved, checkTarget;
M.scanner.init = function(newSource, targetString)
  source = newSource;
  target = LuaTarget[ targetString ];
  start = 1;
  current = 1;
  lineStart = 1;
  line = 1;
end;
local scanAction = {};
scanAction[ "(" ] = function()
  do return makeToken("LEFT_PAREN") end
end;
scanAction[ ")" ] = function()
  do return makeToken("RIGHT_PAREN") end
end;
scanAction[ "{" ] = function()
  do return makeToken("LEFT_BRACE") end
end;
scanAction[ "}" ] = function()
  do return makeToken("RIGHT_BRACE") end
end;
scanAction[ ":" ] = function()
  do return makeToken("COLON") end
end;
scanAction[ ";" ] = function()
  do return makeToken("SEMICOLON") end
end;
scanAction[ "#" ] = function()
  do return makeToken("HASH") end
end;
scanAction[ "@" ] = function()
  do return makeToken("AT") end
end;
scanAction[ "~" ] = function()
  checkTarget("5.3");
  do return makeToken("TILDE") end
end;
scanAction[ "?" ] = function()
  do return makeToken("QUESTION") end
end;
scanAction[ "," ] = function()
  do return makeToken("COMMA") end
end;
scanAction[ "\n" ] = function()
  local t = makeToken("NEWLINE");
  lineStart = current;
  line = line + (1);
  do return t end
end;
scanAction[ " " ] = function()
  while peek():match("[ \t\r]") do
    advance();
  end
end;
scanAction[ "\t" ] = scanAction[ " " ];
scanAction[ "\r" ] = scanAction[ " " ];
scanAction[ "." ] = function(c)
  if match(".") then
    if match("=") then
      do return makeToken("DOT_DOT_EQ") end
    end
    if match(".") then
      do return makeToken("DOT_DOT_DOT") end
    end
    do return makeToken("DOT_DOT") end
  end
  if isDigit(peek()) then
    do return number(c) end
  end
  do return makeToken("DOT") end
end;
scanAction[ "[" ] = function()
  if match("[") then
    do return longString(0) end
  end
  if match("=") then
    local level = 1;
    while peek() == "=" do
      advance();
      level = level + (1);
    end
    if match("[") then
      do return longString(level) end
    end
    error(makeError("Unexpected character combination."));
  end
  do return makeToken("LEFT_BRACKET") end
end;
scanAction[ "]" ] = function()
  do return makeToken("RIGHT_BRACKET") end
end;
scanAction[ "-" ] = function()
  if match("-") then
    skipLineComment();
  elseif match("*") then
    SkipBlockComment();
  else
    do return makeToken(match("=") and "MINUS_EQ" or "MINUS") end
  end
end;
scanAction[ "+" ] = function()
  do return makeToken(match("=") and "PLUS_EQ" or "PLUS") end
end;
scanAction[ "/" ] = function()
  if match("/") then
    checkTarget("5.3");
    do return makeToken(match("=") and "SLASH_SLASH_EQ" or "SLASH_SLASH") end
  else
    do return makeToken(match("=") and "SLASH_EQ" or "SLASH") end
  end
end;
scanAction[ "*" ] = function()
  if match("*") then
    do return makeToken(match("=") and "STAR_STAR_EQ" or "STAR_STAR") end
  else
    do return makeToken(match("=") and "STAR_EQ" or "STAR") end
  end
end;
scanAction[ "!" ] = function()
  do return makeToken(match("=") and "BANG_EQ" or "BANG") end
end;
scanAction[ "^" ] = function()
  checkTarget("5.3");
  do return makeToken(match("=") and "CARET_EQ" or "CARET") end
end;
scanAction[ "%" ] = function()
  do return makeToken(match("=") and "PERCENT_EQ" or "PERCENT") end
end;
scanAction[ "|" ] = function()
  checkTarget("5.3");
  do return makeToken(match("=") and "PIPE_EQ" or "PIPE") end
end;
scanAction[ "&" ] = function()
  checkTarget("5.3");
  do return makeToken(match("=") and "AMP_EQ" or "AMP") end
end;
scanAction[ "=" ] = function()
  do return makeToken(match("=") and "EQUAL_EQ" or "EQUAL") end
end;
scanAction[ "<" ] = function()
  if match("<") then
    checkTarget("5.3");
    do return makeToken(match("=") and "LT_LT_EQ" or "LT_LT") end
  else
    do return makeToken(match("=") and "LT_EQ" or "LT") end
  end
end;
scanAction[ ">" ] = function()
  if match(">") then
    checkTarget("5.3");
    do return makeToken(match("=") and "GT_GT_EQ" or "GT_GT") end
  else
    do return makeToken(match("=") and "GT_EQ" or "GT") end
  end
end;
scanAction[ "\"" ] = function()
  do return shortString("\"") end
end;
scanAction[ "'" ] = function()
  do return shortString("'") end
end;
M.scanner.scanToken = function()
  while true do
    start = current;
    if isAtEnd() then
      do return makeToken("EOF") end
    end
    local c = advance();
    if isDigit(c) then
      do return number(c) end
    end
    if isAlpha(c) then
      do return identifier() end
    end
    do
      local action = scanAction[ c ]
      if action then
        do
          local result = action(c)
          if result then
            do return result end
          end
        end
      else
        error(makeError("Unexpected character."));
      end
    end
  end
end;
isAtEnd = function()
  do return current > #source end
end;
makeToken = function(type)
  do return {
    type = type,
    start = start,
    length = current - start,
    line = line,
    character = start - lineStart + 1,
    text = source:sub(start, current - 1)
  } end
end;
makeError = function(message)
  local token = makeToken("ERROR");
  local where = isAtEnd() and "end" or string.format("'%.50s'", token.text);
  do return Error(token.line, token.character, where, message) end
end;
advance = function(step)
  if step == nil then step = 1 end
  current = current + (step);
  local i = current - 1;
  do return source:sub(i, i) end
end;
peek = function()
  local i = current;
  do return source:sub(i, i) end
end;
peekNext = function(step)
  if step == nil then step = 1 end
  local i = current + step;
  do return source:sub(i, i) end
end;
match = function(expected)
  local i = current;
  if source:sub(i, i) ~= expected then
    do return false end
  end
  current = current + (1);
  do return true end
end;
skipLineComment = function()
  while peek() ~= "\n" and not isAtEnd() do
    advance();
  end
end;
SkipBlockComment = function()
  while true do
    if peek() == "\n" then
      lineStart = current + 1;
      line = line + (1);
    end
    if isAtEnd() then
      do return end
    end
    if peek() == "*" and peekNext() == "-" then
      advance(2);
      do break end;
    end
    advance();
  end
end;
local keywords = {
  [ "and" ] = "AND",
  [ "as" ] = "AS",
  [ "break" ] = "BREAK",
  [ "continue" ] = "CONTINUE",
  [ "do" ] = "RESERVED_LUA",
  [ "end" ] = "ELSE",
  [ "else" ] = "ELSE",
  [ "elseif" ] = "ELSEIF",
  [ "false" ] = "FALSE",
  [ "for" ] = "FOR",
  [ "from" ] = "FROM",
  [ "function" ] = "FUNCTION",
  [ "global" ] = "GLOBAL",
  [ "goto" ] = "RESERVED_LUA",
  [ "if" ] = "IF",
  [ "import" ] = "IMPORT",
  [ "in" ] = "IN",
  [ "local" ] = "RESERVED_LUA",
  [ "method" ] = "METHOD",
  [ "nil" ] = "NIL",
  [ "not" ] = "RESERVED_LUA",
  [ "or" ] = "OR",
  [ "repeat" ] = "REPEAT",
  [ "return" ] = "RETURN",
  [ "then" ] = "RESERVED_LUA",
  [ "true" ] = "TRUE",
  [ "until" ] = "UNTIL",
  [ "var" ] = "VAR",
  [ "while" ] = "WHILE"
};
identifierType = function()
  local identifier = source:sub(start, current - 1);
  if identifier:match("^_hurdytemp[0-9]+$") then
    do return "HURDY_TEMP" end
  end
  for name, type in pairs(keywords) do
    if identifier == name then
      do return type end
    end
  end
  do return "IDENTIFIER" end
end;
shortString = function(delimiter)
  local escapes = {};
  while peek() ~= delimiter and not isAtEnd() do
    if peek() == "\\" then
      local p = peekNext();
      if p == delimiter or p == "\\" then
        advance(2);
      elseif p == '\n' then
        advance(2);
        lineStart = current + 1;
        line = line + (1);
      elseif p == 'z' then
        local escape = {
          type = "Z"
        };
        escape.start = current - start + 1;
        advance(2);
        while true do
          local c = peek();
          if c:match("[ \t\r]") then
            advance();
          elseif c == "\n" then
            advance();
            lineStart = current + 1;
            line = line + (1);
          else
            do break end;
          end
        end
        escape["end"] = current - start + 1;
        escapes[ #escapes + 1 ] = escape;
      elseif p == "x" then
        local escape = {
          type = "HEX"
        };
        escape.start = current - start + 1;
        escape["end"] = escape.start + 4;
        advance(2);
        local hex = source:sub(current, current + 1);
        if not hex:match("%x%x") then
          error(makeError("Hexadecimal digit expected in escape sequence."));
        end
        advance(2);
        escape.character = tonumber(hex, 16);
        escapes[ #escapes + 1 ] = escape;
      elseif p == "u" then
        local escape = {
          type = "CODEPOINT"
        };
        escape.start = current - start + 1;
        advance(2);
        if not match('{') then
          error(makeError("Expected '{'."));
        end
        local hexStart;
        local n = 0;
        local foundDigit = false;
        while isHex(peek()) do
          foundDigit = true;
          local c = advance();
          if hexStart then
            n = n + (1);
            if n > 8 then
              error(makeError("UTF-8 codepoint too large."));
            end
          elseif c ~= '0' then
            hexStart = current - 1;
          end
        end
        if not foundDigit then
          error(makeError("Expected Hexadecimal digit."));
        end
        if not match('}') then
          error(makeError("Expected '}'."));
        end
        escape["end"] = current - start + 1;
        escape.character = hexStart and tonumber(source:sub(hexStart, current - 2), 16) or 0;
        if escape.character > 0x7fffffff then
          error(makeError("UTF-8 codepoint too large."));
        end
        escapes[ #escapes + 1 ] = escape;
      else
        advance();
      end
    elseif peek() == '\n' then
      do break end;
    else
      advance();
    end
  end
  if isAtEnd() or peek() == '\n' then
    error(makeError("Unterminated string."));
  end
  advance();
  local token = makeToken("STRING");
  token.escapes = escapes;
  do return token end
end;
longString = function(level)
  while true do
    while true do
      local c = peek();
      if c == "]" or isAtEnd() then
        do break end;
      end
      if c == "\n" then
        lineStart = current + 1;
        line = line + (1);
      end
      advance();
    end
    if not isAtEnd() then
      local found = 0;
      advance();
      while found < level and peek() == '=' do
        found = found + (1);
        advance();
      end
      if found == level and peek() == ']' then
        advance();
        do return makeToken("STRING") end
      end
    else
      error(makeError("Unterminated string."));
    end
  end
end;
isDigit = function(c)
  do return c:match("[0-9]") end
end;
isAlpha = function(c)
  do return c:match("[a-zA-Z_]") end
end;
isHex = function(c)
  do return c:match("[a-fA-F0-9]") end
end;
number = function(c)
  local i, j;
  if c == "." then
    i, j = source:find("^[0-9]+", current);
  else
    if c == "0" then
      i, j = source:find("^[xX][0-9a-fA-F]+", current);
    end
    if not i then
      i, j = source:find("^[0-9]*%.?[0-9]*", current);
    end
  end
  advance(j - i + 1);
  do return makeToken("NUMBER") end
end;
identifier = function()
  local i, j = source:find("^[a-zA-Z0-9_]*", current);
  advance(j - i + 1);
  local type = identifierType();
  if type == "AND" then
    if match('=') then
      do return makeToken("AND_EQ") end
    end
  elseif type == "OR" then
    if match('=') then
      do return makeToken("OR_EQ") end
    end
  end
  local result = makeToken(type);
  if (type ~= "IDENTIFIER") then
    result.keyword = isLuaReserved(type) and "LUA" or "HURDY";
  end
  do return result end
end;
local LuaReserved = {
  [ "AND" ] = true,
  [ "BREAK" ] = true,
  [ "ELSE" ] = true,
  [ "ELSEIF" ] = true,
  [ "FALSE" ] = true,
  [ "FOR" ] = true,
  [ "FUNCTION" ] = true,
  [ "IF" ] = true,
  [ "IN" ] = true,
  [ "NIL" ] = true,
  [ "OR" ] = true,
  [ "RETURN" ] = true,
  [ "REPEAT" ] = true,
  [ "TRUE" ] = true,
  [ "UNTIL" ] = true,
  [ "WHILE" ] = true,
  [ "RESERVED_LUA" ] = true
};
isLuaReserved = function(type)
  do return LuaReserved[ type ] or false end
end;
checkTarget = function(required)
  if target >= LuaTarget[ required ] then
    do return end
  end
  if required == "jit" then
    error(makeError("Feature requires LuaJIT or Lua 5.2+"));
  end
  if required == "5.2" then
    error(makeError("Feature requires Lua 5.2+"));
  end
  if required == "5.3" then
    error(makeError("Feature requires Lua 5.3+"));
  end
end;
