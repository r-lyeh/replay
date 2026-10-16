local _hurdytemp0
local path = (...):gsub("[^%.]*$", "");
local M = require(path .. "main");
require(path .. "parser");
require(path .. "resolver");
_hurdytemp0 = M
local Error = _hurdytemp0.Error
local Stmt = _hurdytemp0.Stmt
local Expr = _hurdytemp0.Expr
local NULL = _hurdytemp0.NULL
_hurdytemp0 = nil
local visit = {};
local stack;
local generate, newArray, newTable, closeEntry, setFieldString, setFieldInteger, setFieldBoolean, setFieldNull;
M.ast = function(statements)
  stack = {
    {}
  };
  for _, stmt in ipairs(statements) do
    generate(stmt);
  end
  do return stack[ 1 ] end
end;
generate = function(t, field)
  newTable(field);
  do
    local mt = getmetatable(t)
    if mt then
      visit[ mt ](t);
    else
      setFieldString("type", "token");
      setFieldString("text", t.text);
      setFieldInteger("start", t.start);
      setFieldInteger("length", t.length);
      setFieldInteger("line", t.line);
      setFieldInteger("character", t.character);
    end
  end
  closeEntry();
end;
newArray = function(field)
  local t = {};
  local current = stack[ #stack ];
  do
    local name = field
    if name then
      current[ name ] = t;
    else
      current[ #current + 1 ] = t;
    end
  end
  stack[ #stack + 1 ] = t;
end;
newTable = newArray;
closeEntry = function()
  stack[ #stack ] = nil;
end;
setFieldString = function(field, value)
  stack[ #stack ][ field ] = value;
end;
setFieldInteger = setFieldString;
setFieldBoolean = setFieldString;
setFieldNull = setFieldString;
visit[ Stmt.Expression ] = function(stmt)
  setFieldString("type", "expression statement");
  generate(stmt.expression, "expression");
end;
visit[ Stmt.Var ] = function(stmt)
  setFieldString("type", "variable declaration");
  setFieldBoolean("global", not stmt["local"]);
  newArray("names");
  for _, name in ipairs(stmt.names) do
    generate(name);
  end
  closeEntry();
  newArray("initializers");
  for _, initializer in ipairs(stmt.initializers) do
    generate(initializer);
  end
  closeEntry();
end;
visit[ Stmt.Block ] = function(stmt)
  setFieldString("type", "block");
  newArray("statements");
  for _, s in ipairs(stmt.statements) do
    generate(s);
  end
  closeEntry();
end;
visit[ Stmt.If ] = function(stmt)
  setFieldString("type", "if");
  generate(stmt.ifData.condition, "condition");
  do
    local t = stmt.ifData.identifier
    if t then
      generate(t, "identifier");
    else
      setFieldNull("identifier");
    end
  end
  generate(stmt.ifData.branch, "thenBranch");
  do
    local branch = stmt.elseBranch
    if branch then
      generate(branch, "elseBranch");
    else
      setFieldNull("elseBranch");
    end
  end
  if #stmt.elseifData == 0 then
    setFieldNull("elseif");
    do return end
  end
  newArray("elseif");
  for _, data in ipairs(stmt.elseifData) do
    newTable();
    generate(data.condition, "condition");
    do
      local t = data.identifier
      if t then
        generate(t, "identifier");
      else
        setFieldNull("identifier");
      end
    end
    generate(data.branch, "branch");
    closeEntry();
  end
  closeEntry();
end;
visit[ Stmt.While ] = function(stmt)
  setFieldString("type", "while");
  generate(stmt.condition, "condition");
  generate(stmt.body, "body");
end;
visit[ Stmt.ForNumeric ] = function(stmt)
  setFieldString("type", "numeric for");
  generate(stmt.identifier, "identifier");
  generate(stmt.initialValue, "initialValue");
  generate(stmt.limit, "limit");
  do
    local step = stmt.step
    if step then
      generate(step, "step");
    else
      setFieldNull("step");
    end
  end
  do
    local body = stmt.body
    if body then
      generate(body, "body");
    else
      setFieldNull("body");
    end
  end
end;
visit[ Stmt.ForGeneric ] = function(stmt)
  setFieldString("type", "generic for");
  newArray("name list");
  for _, name in ipairs(stmt.namelist) do
    generate(name);
  end
  closeEntry();
  newArray("expression list");
  for _, expr in ipairs(stmt.explist) do
    generate(expr);
  end
  closeEntry();
  do
    local body = stmt.body
    if body then
      generate(body, "body");
    else
      setFieldNull("body");
    end
  end
end;
visit[ Stmt.Return ] = function(stmt)
  setFieldString("type", "return");
  if #stmt.values > 0 then
    newArray("values");
    for _, expr in ipairs(stmt.values) do
      generate(expr);
    end
    closeEntry();
  else
    setFieldNull("values");
  end
end;
visit[ Stmt.Assign ] = function(stmt)
  setFieldString("type", "assign");
  newArray("names");
  for _, expr in ipairs(stmt.names) do
    generate(expr);
  end
  closeEntry();
  if #stmt.values > 0 then
    newArray("values");
    for _, expr in ipairs(stmt.values) do
      generate(expr);
    end
    closeEntry();
  else
    setFieldNull("values");
  end
end;
visit[ Stmt.OpAssign ] = function(stmt)
  setFieldString("type", "operator assign");
  generate(stmt.name, "name");
  generate(stmt.op, "operator");
  generate(stmt.value, "value");
end;
visit[ Stmt.Break ] = function(stmt)
  setFieldString("type", "break");
  generate(stmt.token, "token");
end;
visit[ Stmt.Import ] = function(stmt)
  setFieldString("type", "import");
  generate(stmt.from, "source");
  newArray("data");
  for _, entry in ipairs(stmt.data) do
    newTable();
    generate(entry.name, "name");
    generate(entry.as, "as");
    closeEntry();
  end
  closeEntry();
end;
visit[ Stmt.Repeat ] = function(stmt)
  setFieldString("type", "repeat");
  generate(stmt.condition, "condition");
  generate(stmt.body, "body");
end;
visit[ Stmt.Continue ] = function(stmt)
  setFieldString("type", "continue");
  generate(stmt.token, "token");
end;
visit[ Expr.Binary ] = function(expr)
  setFieldString("type", "binary");
  generate(expr.op, "operator");
  generate(expr.left, "left expression");
  generate(expr.right, "right expression");
end;
visit[ Expr.Grouping ] = function(expr)
  setFieldString("type", "grouping");
  generate(expr.expression, "expression");
end;
visit[ Expr.Literal ] = function(expr)
  setFieldString("type", "literal");
  generate(expr.value, "value");
end;
visit[ Expr.Unary ] = function(expr)
  setFieldString("type", "unary");
  generate(expr.op, "operator");
  generate(expr.expression, "expression");
end;
visit[ Expr.Variable ] = function(expr)
  setFieldString("type", "variable");
  generate(expr.name, "name");
end;
visit[ Expr.Access ] = function(expr)
  setFieldString("type", "access");
  generate(expr.parent, "parent");
  do
    local name = expr.name
    if name then
      generate(name, "name");
    else
      setFieldNull("name");
    end
  end
  do
    local key = expr.key
    if key then
      generate(key, "key");
    else
      setFieldNull("key");
    end
  end
end;
visit[ Expr.Call ] = function(expr)
  setFieldString("type", "call");
  if expr.method then
    generate(expr.method, "method");
  else
    setFieldNull("method");
  end
  generate(expr.parent, "callee");
  newArray("arguments");
  for _, arg in ipairs(expr.arguments) do
    generate(arg);
  end
  closeEntry();
end;
visit[ Expr.Function ] = function(expr)
  setFieldString("type", "function");
  setFieldBoolean("method", expr.method);
  setFieldBoolean("vararg", expr.vararg);
  newArray("parameters");
  for i = 1, #expr.parameters do
    newTable();
    do
      setFieldString("type", "function parameter");
      generate(expr.parameters[ i ], "token");
      local def = expr.defaults[ i ];
      if def ~= NULL then
        generate(def, "default");
      else
        setFieldNull("default");
      end
    end
    closeEntry();
  end
  closeEntry();
  generate(expr.body, "body");
end;
visit[ Expr.TableConstructor ] = function(expr)
  setFieldString("type", "table");
  newArray("entries");
  for _, entry in ipairs(expr.entries) do
    newTable();
    do
      setFieldString("type", "table entry");
      generate(entry.value, "value");
      do
        local name = entry.name
        if name then
          generate(name, "name");
        else
          setFieldNull("name");
        end
      end
      do
        local key = entry.key
        if key then
          generate(key, "key");
        else
          setFieldNull("key");
        end
      end
    end
    closeEntry();
  end
  closeEntry();
end;
visit[ Expr.TableComprehension ] = function(expr)
  setFieldString("type", "table comprehension");
  local type = expr.type;
  if type == "ARRAY" then
    setFieldString("comprehension type", "array");
  elseif type == "HASH" then
    setFieldString("comprehension type", "hash");
  else
    setFieldString("comprehension type", "hash single");
  end
  do
    local key = expr.key
    if key then
      generate(key, "key");
    else
      setFieldNull("key");
    end
  end
  generate(expr.value, "value");
  newArray("forLoops");
  do
    for _, loop in ipairs(expr.forLoops) do
      newTable();
      generate(loop.stmt, "for");
      do
        local cond = loop.condition
        if cond then
          generate(cond, "condition");
        else
          setFieldNull("condition");
        end
      end
      closeEntry();
    end
  end
  closeEntry();
end;
visit[ Expr.Dddot ] = function(expr)
  setFieldString("type", "vararg");
  generate(expr.token, "token");
end;
