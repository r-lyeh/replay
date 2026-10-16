local _hurdytemp0
local path = (...):gsub("[^%.]*$", "");
local M = require(path .. "main");
local Stmts = {
  {
    __name = "Var",
    call = function()
      do return {
        names = {},
        initializers = {},
        functionDeclaration = false
      } end
    end
  },
  {
    __name = "Return",
    call = function()
      do return {
        values = {}
      } end
    end
  },
  {
    __name = "Break",
    call = function(token)
      do return {
        token = token
      } end
    end
  },
  {
    __name = "Continue",
    call = function(token)
      do return {
        token = token
      } end
    end
  },
  {
    __name = "Block",
    call = function()
      do return {
        statements = {},
        bodyOfOther = false
      } end
    end
  },
  {
    __name = "Assign",
    call = function()
      do return {
        names = {},
        values = {}
      } end
    end
  },
  {
    __name = "OpAssign",
    call = function(op, name, value)
      do return {
        op = op,
        name = name,
        value = value
      } end
    end
  },
  {
    __name = "Import",
    call = function()
      do return {
        from = nil,
        data = {}
      } end
    end
  },
  {
    __name = "While",
    call = function(condition, body)
      do return {
        condition = condition,
        body = body,
        hasContinue = false
      } end
    end
  },
  {
    __name = "Repeat",
    call = function(condition, body)
      do return {
        condition = condition,
        body = body,
        hasContinue = false
      } end
    end
  },
  {
    __name = "Expression",
    call = function(expression)
      do return {
        expression = expression
      } end
    end
  },
  {
    __name = "If",
    call = function()
      do return {
        ifData = {},
        elseifData = {}
      } end
    end
  },
  {
    __name = "ForGeneric",
    call = function()
      do return {
        namelist = {},
        explist = {},
        hasContinue = false
      } end
    end
  },
  {
    __name = "ForNumeric",
    call = function()
      do return {
        hasContinue = false
      } end
    end
  }
};
M.Stmt = {};
local mt = {
  __call = function(self, ...)
    local res = self.call(...);
    if M.debug then
      res.__type = self.__name;
    end
    do return setmetatable(res, self) end
  end
};
for _, t in ipairs(Stmts) do
  t.__type = "statement";
  setmetatable(t, mt);
  M.Stmt[ t.__name ] = t;
end
