local _hurdytemp0
local path = (...):gsub("[^%.]*$", "");
local M = require(path .. "main");
local Exprs = {
  {
    __name = "Binary",
    call = function(left, op, right)
      do return {
        left = left,
        right = right,
        op = op,
        line = {
          left.line[ 1 ],
          right.line[ 1 ]
        }
      } end
    end
  },
  {
    __name = "Unary",
    call = function(op, expression)
      do return {
        expression = expression,
        op = op,
        line = expression.line
      } end
    end
  },
  {
    __name = "Literal",
    call = function(value)
      do return {
        value = value,
        line = {
          value.line,
          value.line
        }
      } end
    end
  },
  {
    __name = "Grouping",
    call = function(expression)
      do return {
        expression = expression,
        line = expression.line,
        _accessable = true
      } end
    end
  },
  {
    __name = "Variable",
    call = function(name)
      do return {
        name = name,
        line = {
          name.line,
          name.line
        },
        _assignable = true,
        _accessable = true
      } end
    end
  },
  {
    __name = "Access",
    call = function(expression, name, key)
      do return {
        name = name,
        key = key,
        line = {
          expression.line[ 1 ],
          name and name.line or key.line[ 2 ]
        },
        parent = expression,
        _assignable = true,
        _accessable = true
      } end
    end
  },
  {
    __name = "Call",
    call = function()
      do return {
        method = nil,
        arguments = {},
        line = {
          0,
          0
        },
        _accessable = true
      } end
    end
  },
  {
    __name = "Function",
    call = function()
      do return {
        parameters = {},
        defaults = {},
        method = false,
        line = {
          0,
          0
        },
        vararg = false
      } end
    end
  },
  {
    __name = "TableConstructor",
    call = function()
      do return {
        entries = {},
        line = {
          0,
          0
        }
      } end
    end
  },
  {
    __name = "TableComprehension",
    call = function()
      do return {
        forLoops = {},
        line = {
          0,
          0
        }
      } end
    end
  },
  {
    __name = "Dddot",
    call = function(token)
      do return {
        token = token,
        line = {
          token.line,
          token.line
        }
      } end
    end
  }
};
M.Expr = {};
local mt = {
  __call = function(self, ...)
    local res = self.call(...);
    if M.debug then
      res.__type = self.__name;
    end
    do return setmetatable(res, self) end
  end
};
for _, t in ipairs(Exprs) do
  t.__type = "expression";
  setmetatable(t, mt);
  M.Expr[ t.__name ] = t;
end
