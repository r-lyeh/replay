local _hurdytemp0
local path = (...):gsub("[^%.]*$", "");
local M = require(path .. "main");
require(path .. "error");
require(path .. "expr");
require(path .. "stmt");
_hurdytemp0 = M
local Error = _hurdytemp0.Error
local Stmt = _hurdytemp0.Stmt
local Expr = _hurdytemp0.Expr
local NULL = _hurdytemp0.NULL
_hurdytemp0 = nil
local visit = {};
local scopes, currentFunction, resolveDeclarations;
local resolve, beginScope, endScope, declare, declareImplicitLocal, resolveLocal, makeError;
M.resolve = function(statements, _resolveDeclarations)
  if _resolveDeclarations == nil then _resolveDeclarations = true end
  scopes = {
    {}
  };
  currentFunction = nil;
  resolveDeclarations = _resolveDeclarations;
  for _, t in ipairs(statements) do
    resolve(t);
  end
end;
resolve = function(t)
  visit[ getmetatable(t) ](t);
end;
beginScope = function()
  if not resolveDeclarations then
    do return end
  end
  scopes[ #scopes + 1 ] = {};
end;
endScope = function()
  if not resolveDeclarations then
    do return end
  end
  scopes[ #scopes ] = nil;
end;
declare = function(name, isGlobal)
  if isGlobal == nil then isGlobal = false end
  if not resolveDeclarations then
    do return end
  end
  if #scopes == 0 then
    do return end
  end
  local s = name.text;
  local scope = scopes[ #scopes ];
  if isGlobal then
    for i = #scopes, 1, -1 do
      local scope = scopes[ i ];
      local v = scope[ s ];
      if v ~= nil then
        if v then
          do break end;
        end
        error(makeError(name, "Cannot declare global variable if the variable is already local in the scope."));
      end
    end
  end
  scope[ s ] = isGlobal;
end;
declareImplicitLocal = function(name)
  if not resolveDeclarations then
    do return end
  end
  local scope = scopes[ #scopes ];
  scope[ name ] = false;
end;
resolveLocal = function(expr)
  if not resolveDeclarations then
    do return end
  end
  local s = expr.name.text;
  for i = #scopes, 1, -1 do
    if scopes[ i ][ s ] ~= nil then
      do return end
    end
  end
  error(makeError(expr.name, "Cannot assign to an undeclared variable."));
end;
makeError = function(token, message)
  do return Error(token.line, token.character, token.text, message) end
end;
visit[ Stmt.Expression ] = function(stmt)
  resolve(stmt.expression);
end;
visit[ Stmt.Var ] = function(stmt)
  if not stmt.functionDeclaration then
    for _, initializer in ipairs(stmt.initializers) do
      resolve(initializer);
    end
    for _, name in ipairs(stmt.names) do
      declare(name, not stmt["local"]);
    end
  else
    declare(stmt.names[ 1 ], not stmt["local"]);
    resolve(stmt.initializers[ 1 ]);
  end
end;
visit[ Stmt.Block ] = function(stmt)
  if not stmt.bodyOfOther then
    beginScope();
  end
  for _, subStmt in ipairs(stmt.statements) do
    resolve(subStmt);
  end
  if not stmt.bodyOfOther then
    endScope();
  end
end;
visit[ Stmt.If ] = function(stmt)
  local numIdentifierScopes = 0;
  resolve(stmt.ifData.condition);
  do
    local t = stmt.ifData.identifier
    if t then
      numIdentifierScopes = numIdentifierScopes + (1);
      beginScope();
      declareImplicitLocal(t.text);
    end
  end
  beginScope();
  resolve(stmt.ifData.branch);
  endScope();
  for _, data in ipairs(stmt.elseifData) do
    resolve(data.condition);
    do
      local t = data.identifier
      if t then
        numIdentifierScopes = numIdentifierScopes + (1);
        beginScope();
        declareImplicitLocal(t.text);
      end
    end
    beginScope();
    resolve(data.branch);
    endScope();
  end
  if stmt.elseBranch then
    beginScope();
    resolve(stmt.elseBranch);
    endScope();
  end
  for i = 1, numIdentifierScopes do
    endScope();
  end
end;
visit[ Stmt.While ] = function(stmt)
  resolve(stmt.condition);
  beginScope();
  resolve(stmt.body);
  endScope();
end;
visit[ Stmt.ForNumeric ] = function(stmt)
  resolve(stmt.initialValue);
  resolve(stmt.limit);
  if stmt.step then
    resolve(stmt.step);
  end
  beginScope();
  declare(stmt.identifier);
  resolve(stmt.body);
  endScope();
end;
visit[ Stmt.ForGeneric ] = function(stmt)
  for _, expr in ipairs(stmt.explist) do
    resolve(expr);
  end
  beginScope();
  for _, name in ipairs(stmt.namelist) do
    declare(name);
  end
  resolve(stmt.body);
  endScope();
end;
visit[ Stmt.Return ] = function(stmt)
  for _, value in ipairs(stmt.values) do
    resolve(value);
  end
end;
visit[ Stmt.Assign ] = function(stmt)
  for _, value in ipairs(stmt.values) do
    resolve(value);
  end
  for _, name in ipairs(stmt.names) do
    if getmetatable(name) == Expr.Variable then
      resolveLocal(name);
    else
      resolve(name);
    end
  end
end;
visit[ Stmt.OpAssign ] = function(stmt)
  resolve(stmt.value);
  local name = stmt.name;
  if getmetatable(name) == Expr.Variable then
    resolveLocal(name);
  else
    resolve(name);
  end
end;
visit[ Stmt.Break ] = function(stmt)
  
end;
visit[ Stmt.Import ] = function(stmt)
  for _, entry in ipairs(stmt.data) do
    declare(entry.as, false);
  end
end;
visit[ Stmt.Repeat ] = function(stmt)
  resolve(stmt.condition);
  beginScope();
  resolve(stmt.body);
  endScope();
end;
visit[ Stmt.Continue ] = function(stmt)
  
end;
visit[ Expr.Binary ] = function(expr)
  resolve(expr.left);
  resolve(expr.right);
end;
visit[ Expr.Grouping ] = function(expr)
  resolve(expr.expression);
end;
visit[ Expr.Literal ] = function(expr)
  
end;
visit[ Expr.Unary ] = function(expr)
  resolve(expr.expression);
end;
visit[ Expr.Variable ] = function(expr)
  
end;
visit[ Expr.Access ] = function(expr)
  resolve(expr.parent);
end;
visit[ Expr.Call ] = function(expr)
  resolve(expr.parent);
  for _, argument in ipairs(expr.arguments) do
    resolve(argument);
  end
end;
visit[ Expr.Function ] = function(expr)
  local previousFunction = currentFunction;
  currentFunction = expr;
  beginScope();
  if expr.method then
    declareImplicitLocal("self");
  end
  for _, param in ipairs(expr.parameters) do
    declare(param);
  end
  for _, def in ipairs(expr.defaults) do
    if def ~= NULL then
      resolve(def);
    end
  end
  resolve(expr.body);
  endScope();
  currentFunction = previousFunction;
end;
visit[ Expr.TableConstructor ] = function(expr)
  for _, entry in ipairs(expr.entries) do
    do
      local key = entry.key
      if key then
        resolve(key);
      end
    end
    resolve(entry.value);
  end
end;
visit[ Expr.TableComprehension ] = function(expr)
  for _, loop in ipairs(expr.forLoops) do
    local stmt = loop.stmt;
    if getmetatable(stmt) == Stmt.ForNumeric then
      resolve(stmt.initialValue);
      resolve(stmt.limit);
      do
        local step = stmt.step
        if step then
          resolve(step);
        end
      end
      beginScope();
      declare(stmt.identifier);
    else
      for _, expr in ipairs(stmt.explist) do
        resolve(expr);
      end
      beginScope();
      for _, name in ipairs(stmt.namelist) do
        declare(name);
      end
    end
    do
      local cond = loop.condition
      if cond then
        resolve(cond);
      end
    end
  end
  do
    local key = expr.key
    if key then
      resolve(key);
    end
  end
  resolve(expr.value);
  for i = 1, #expr.forLoops do
    endScope();
  end
end;
visit[ Expr.Dddot ] = function(expr)
  if currentFunction and not currentFunction.vararg then
    error(makeError(expr.token, "Cannot use ... outside of vararg function."));
  end
end;
