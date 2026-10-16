local _hurdytemp0
local path = (...):gsub("[^%.]*$", "");
local M = require(path .. "main");
local Error = {};
local mt = {
  __index = Error
};
local getMessage;
getMessage = function(self, chunkName)
  local chunkText = chunkName and #chunkName > 0 and string.format("<%s>:", chunkName) or "";
  do return string.format("[hurdy:%s%d:%d] Error near %s: %s", chunkText, self.line, self.character, self.where, self.message) end
end;
M.Error = function(line, character, where, message)
  do return {
    hurdyError = true,
    line = line,
    character = character,
    where = where,
    message = message
  } end
end;
M.errorMessage = function(t, chunkName)
  do return t.hurdyError and getMessage(t, chunkName) or t end
end;
