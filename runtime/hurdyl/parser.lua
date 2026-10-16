local _hurdytemp0
local path = (...):gsub("[^%.]*$", "");
local M = require(path .. "main");
require(path .. "error");
require(path .. "scanner");
require(path .. "stmt");
require(path .. "expr");
_hurdytemp0 = M
local Error = _hurdytemp0.Error
local scanner = _hurdytemp0.scanner
local Stmt = _hurdytemp0.Stmt
local Expr = _hurdytemp0.Expr
local LuaTarget = _hurdytemp0.LuaTarget
_hurdytemp0 = nil
local NULL = {};
M.NULL = NULL;
local tokens, current, loopStack, target;
local match, check, advance, isAtEnd, peek, peekNext, previous, makeError, ignoreNewlines, consumeNewLines, checkAfterNewlines, consume, consumeIdentifier, flagBlockasBody, beginLoop, endLoop, insideLoop, declaration, varDeclaration, statement, importStatement, forStatement, ifStatement, ifIdentifier, returnStatement, breakStatement, continueStatement, whileStatement, repeatStatement, assignmentStatement, expressionStatement, block, expression, binary, unary, accessOrCall, finishCall, primary, functionConstructor, tableConstructor, tableComprehension;
M.parse = function(source, targetString)
  target = LuaTarget[ targetString ];
  scanner.init(source, targetString);
  tokens = {};
  while true do
    local t = scanner.scanToken();
    table.insert(tokens, t);
    if t.type == "EOF" then
      do break end;
    end
  end
  current = 1;
  loopStack = {};
  local statements = {};
  ignoreNewlines();
  while not isAtEnd() do
    table.insert(statements, declaration());
    consumeNewLines();
    ignoreNewlines();
  end
  do return statements end
end;
match = function(...)
  for i = 1, select("#", ...) do
    local t = select(i, ...);
    if check(t) then
      advance();
      do return true end
    end
  end
  do return false end
end;
check = function(type)
  do return peek().type == type end
end;
advance = function()
  if not isAtEnd() then
    current = current + (1);
  end
  do return previous() end
end;
isAtEnd = function()
  do return peek().type == "EOF" end
end;
peek = function()
  do return tokens[ current ] end
end;
peekNext = function(step)
  do return tokens[ current + step ] end
end;
previous = function()
  do return tokens[ current - 1 ] end
end;
makeError = function(token, message)
  local where;
  local type = token.type;
  if type == "EOF" then
    where = "<eof>";
  elseif type == "NEWLINE" then
    where = "<newline>";
  else
    where = string.format("'%.50s'", token.text);
  end
  do return Error(token.line, token.character, where, message) end
end;
ignoreNewlines = function()
  while check("NEWLINE") do
    advance();
  end
end;
consumeNewLines = function()
  if isAtEnd() then
    do return end
  end
  consume("NEWLINE", "Expect newline.");
  ignoreNewlines();
end;
checkAfterNewlines = function(type)
  for i = current, #tokens do
    local token = tokens[ i ];
    if token.type ~= "NEWLINE" then
      do return token.type == type end
    end
  end
  do return false end
end;
consume = function(type, message)
  if check(type) then
    do return advance() end
  end
  error(makeError(peek(), message));
end;
consumeIdentifier = function(allowHurdyKeyword, allowLuaKeyword, message)
  local token = peek();
  local found = token.type == "IDENTIFIER" or (allowHurdyKeyword and token.keyword == "HURDY") or (allowLuaKeyword and token.keyword == "LUA");
  if found then
    do return advance() end
  end
  error(makeError(token, message));
end;
flagBlockasBody = function(stmt)
  if getmetatable(stmt) == Stmt.Block then
    stmt.bodyOfOther = true;
  end
  do return stmt end
end;
beginLoop = function()
  loopStack[ #loopStack + 1 ] = false;
end;
endLoop = function()
  local hasContinue = loopStack[ #loopStack ];
  loopStack[ #loopStack ] = nil;
  do return hasContinue end
end;
insideLoop = function()
  do return #loopStack > 0 end
end;
declaration = function()
  if match("GLOBAL") then
    do return varDeclaration(true) end
  end
  if match("VAR") then
    do return varDeclaration(false) end
  end
  do return statement() end
end;
varDeclaration = function(isGlobal)
  local p = Stmt.Var();
  p["local"] = not isGlobal;
  if match("FUNCTION", "METHOD") then
    local type = previous().type;
    table.insert(p.names, consume("IDENTIFIER", "Expect function name."));
    table.insert(p.initializers, functionConstructor(type));
    p.functionDeclaration = true;
    do return p end
  end
  table.insert(p.names, consume("IDENTIFIER", "Expect variable name."));
  while match("COMMA") do
    ignoreNewlines();
    table.insert(p.names, consume("IDENTIFIER", "Expect variable name."));
  end
  if match("EQUAL") then
    repeat
      ignoreNewlines();
      table.insert(p.initializers, expression());
    until not match("COMMA");
  end
  do return p end
end;
statement = function()
  if match("FROM") then
    do return importStatement() end
  end
  if match("FOR") then
    do return forStatement() end
  end
  if match("IF") then
    do return ifStatement() end
  end
  if match("RETURN") then
    do return returnStatement() end
  end
  if match("BREAK") then
    do return breakStatement() end
  end
  if match("CONTINUE") then
    do return continueStatement() end
  end
  if match("WHILE") then
    do return whileStatement() end
  end
  if match("REPEAT") then
    do return repeatStatement() end
  end
  if match("LEFT_BRACE") then
    local p = Stmt.Block();
    block(p.statements);
    do return p end
  end
  if match("FUNCTION", "METHOD") then
    local p = Stmt.Assign();
    local type = previous().type;
    local expr = accessOrCall(true);
    local exprType = getmetatable(expr);
    if exprType ~= Expr.Access and exprType ~= Expr.Variable then
      error(makeError(previous(), "Expect identifier"));
    end
    table.insert(p.names, expr);
    table.insert(p.values, functionConstructor(type));
    do return p end
  end
  do return assignmentStatement() end
end;
importStatement = function()
  local p = Stmt.Import();
  local expr = expression();
  p.from = expr;
  if not expr._accessable then
    error(makeError(previous(), "Expect indexable expression."));
  end
  ignoreNewlines();
  consume("IMPORT", "Expect 'import'.");
  repeat
    ignoreNewlines();
    table.insert(p.data, {
      name = consumeIdentifier(true, true, "Expect identifier.")
    });
  until not match("COMMA");
  if match("AS") then
    for i, entry in ipairs(p.data) do
      ignoreNewlines();
      if not match("STAR") then
        entry.as = consumeIdentifier(false, false, "Expect identifier.");
      end
      if i < #p.data then
        consume("COMMA", "Expect comma.");
      end
    end
  end
  for _, entry in ipairs(p.data) do
    entry.as = entry.as or entry.name;
    if entry.as.type ~= "IDENTIFIER" then
      error(makeError(entry.as, "Identifier is a keyword and is not aliased."));
    end
  end
  do return p end
end;
forStatement = function(headerOnly)
  if headerOnly == nil then headerOnly = false end
  local genericFor = Stmt.ForGeneric();
  repeat
    ignoreNewlines();
    table.insert(genericFor.namelist, consume("IDENTIFIER", "Expect variable name."));
  until not match("COMMA");
  if #genericFor.namelist == 1 and match("EQUAL") then
    local p = Stmt.ForNumeric();
    p.identifier = genericFor.namelist[ 1 ];
    ignoreNewlines();
    p.initialValue = expression();
    consume("COMMA", "Expect comma.");
    ignoreNewlines();
    p.limit = expression();
    if match("COMMA") then
      ignoreNewlines();
      p.step = expression();
    end
    if not headerOnly then
      ignoreNewlines();
      beginLoop();
      p.body = flagBlockasBody(declaration());
      p.hasContinue = endLoop();
    end
    do return p end
  end
  ignoreNewlines();
  consume("IN", "Expect 'in'.");
  repeat
    ignoreNewlines();
    table.insert(genericFor.explist, expression());
  until not match("COMMA");
  if not headerOnly then
    ignoreNewlines();
    beginLoop();
    genericFor.body = flagBlockasBody(declaration());
    genericFor.hasContinue = endLoop();
  end
  do return genericFor end
end;
ifStatement = function()
  local p = Stmt.If();
  ignoreNewlines();
  if match("VAR") then
    p.ifData.identifier = ifIdentifier();
  end
  p.ifData.condition = expression();
  ignoreNewlines();
  p.ifData.branch = flagBlockasBody(declaration());
  if not checkAfterNewlines("ELSEIF") and not checkAfterNewlines("ELSE") then
    do return p end
  end
  ignoreNewlines();
  while match("ELSEIF") do
    ignoreNewlines();
    local data = {};
    table.insert(p.elseifData, data);
    if match("VAR") then
      data.identifier = ifIdentifier();
    end
    data.condition = expression();
    ignoreNewlines();
    data.branch = flagBlockasBody(declaration());
    if checkAfterNewlines("ELSEIF") then
      ignoreNewlines();
    end
  end
  if not checkAfterNewlines("ELSE") then
    do return p end
  end
  ignoreNewlines();
  if match("ELSE") then
    ignoreNewlines();
    p.elseBranch = flagBlockasBody(declaration());
  end
  do return p end
end;
ifIdentifier = function()
  local t = consumeIdentifier(false, false, "Expected identifier.");
  consume("EQUAL", "Expected '='.");
  ignoreNewlines();
  do return t end
end;
returnStatement = function()
  local p = Stmt.Return();
  if not isAtEnd() and not check("NEWLINE") and not check("RIGHT_BRACE") and not check("ELSEIF") and not check("ELSE") then
    table.insert(p.values, expression());
    while match("COMMA") do
      ignoreNewlines();
      table.insert(p.values, expression());
    end
  end
  do return p end
end;
breakStatement = function()
  if not insideLoop() then
    error(makeError(previous(), "Cannot break outside a loop."));
  end
  do return Stmt.Break(previous()) end
end;
continueStatement = function()
  if target < LuaTarget.jit then
    error(makeError(previous(), "Continue statement requires LuaJIT or Lua 5.2+"));
  end
  if not insideLoop() then
    error(makeError(previous(), "Cannot continue outside a loop."));
  end
  loopStack[ #loopStack ] = true;
  do return Stmt.Continue(previous()) end
end;
whileStatement = function()
  ignoreNewlines();
  local condition = expression();
  ignoreNewlines();
  beginLoop();
  local body = flagBlockasBody(declaration());
  local flag = endLoop();
  local p = Stmt.While(condition, body);
  p.hasContinue = flag;
  do return p end
end;
repeatStatement = function()
  ignoreNewlines();
  beginLoop();
  local body = flagBlockasBody(declaration());
  local flag = endLoop();
  ignoreNewlines();
  consume("UNTIL", "Expect 'until'.");
  ignoreNewlines();
  local condition = expression();
  local p = Stmt.Repeat(condition, body);
  p.hasContinue = flag;
  do return p end
end;
assignmentStatement = function()
  local p = Stmt.Assign();
  table.insert(p.names, expression());
  while match("COMMA") do
    ignoreNewlines();
    table.insert(p.names, expression());
    if not p.names[ #p.names ]._assignable then
      error(makeError(previous(), "Invalid assignment target."));
    end
  end
  if match("DOT_DOT_EQ", "PLUS_EQ", "MINUS_EQ", "SLASH_EQ", "STAR_EQ", "SLASH_SLASH_EQ", "STAR_STAR_EQ", "BANG_EQ", "CARET_EQ", "PERCENT_EQ", "GT_GT_EQ", "LT_LT_EQ", "AMP_EQ", "PIPE_EQ", "AND_EQ", "OR_EQ") then
    if #p.names > 1 then
      error(makeError(previous(), "Operation assignments can only have one assignment target."));
    end
    ignoreNewlines();
    if not p.names[ 1 ]._assignable then
      error(makeError(previous(), "Invalid assignment target."));
    end
    local token = previous();
    do return Stmt.OpAssign(token, p.names[ 1 ], expression()) end
  end
  if match("EQUAL") then
    if not p.names[ 1 ]._assignable then
      error(makeError(previous(), "Invalid assignment target."));
    end
    repeat
      ignoreNewlines();
      table.insert(p.values, expression());
    until not match("COMMA");
    do return p end
  else
    if #p.names > 1 then
      error(makeError(previous(), "Expect = in assignment."));
    end
    do return expressionStatement(p.names[ 1 ]) end
  end
end;
expressionStatement = function(expr)
  if getmetatable(expr) ~= Expr.Call then
    error(makeError(previous(), "Statements with a single expression must have side-effects."));
  end
  do return Stmt.Expression(expr) end
end;
block = function(statements)
  ignoreNewlines();
  while not check("RIGHT_BRACE") and not isAtEnd() do
    table.insert(statements, declaration());
    if not check("RIGHT_BRACE") then
      consumeNewLines();
    end
  end
  ignoreNewlines();
  consume("RIGHT_BRACE", "Expect '}' after block.");
end;
local binaryOperators = {
  [ "OR" ] = true,
  [ "AND" ] = true,
  [ "GT" ] = true,
  [ "GT_EQ" ] = true,
  [ "LT" ] = true,
  [ "LT_EQ" ] = true,
  [ "BANG_EQ" ] = true,
  [ "EQUAL_EQ" ] = true,
  [ "PIPE" ] = true,
  [ "CARET" ] = true,
  [ "AMP" ] = true,
  [ "LT_LT" ] = true,
  [ "GT_GT" ] = true,
  [ "DOT_DOT" ] = true,
  [ "MINUS" ] = true,
  [ "PLUS" ] = true,
  [ "SLASH" ] = true,
  [ "STAR" ] = true,
  [ "SLASH_SLASH" ] = true,
  [ "PERCENT" ] = true,
  [ "STAR_STAR" ] = true
};
local unaryOperators = {
  [ "BANG" ] = true,
  [ "MINUS" ] = true,
  [ "HASH" ] = true,
  [ "TILDE" ] = true
};
expression = function()
  do return binary() end
end;
binary = function()
  local expr = unary();
  while binaryOperators[ peek().type ] do
    advance();
    local op = previous();
    ignoreNewlines();
    local right = unary();
    expr = Expr.Binary(expr, op, right);
  end
  do return expr end
end;
unary = function()
  while unaryOperators[ peek().type ] do
    advance();
    local op = previous();
    ignoreNewlines();
    local right = unary();
    do return Expr.Unary(op, right) end
  end
  do return accessOrCall() end
end;
accessOrCall = function(dotAccessOnly)
  local expr = primary();
  while true do
    if match("DOT") then
      ignoreNewlines();
      if not expr._accessable then
        error(makeError(previous(), "Expression cannot be indexed."));
      end
      local name = consumeIdentifier(true, true, "Expect identifier after '.'.");
      expr = Expr.Access(expr, name, nil);
    elseif dotAccessOnly then
      do break end;
    elseif match("LEFT_BRACKET") then
      ignoreNewlines();
      if not expr._accessable then
        error(makeError(previous(), "Expression cannot be indexed."));
      end
      expr = Expr.Access(expr, nil, expression());
      ignoreNewlines();
      consume("RIGHT_BRACKET", "Expect ']' after key.");
    elseif match("COLON") then
      ignoreNewlines();
      if not expr._accessable then
        error(makeError(previous(), "Expression cannot be indexed."));
      end
      local _method = consumeIdentifier(true, false, "Expect identifier after ':'.");
      consume("LEFT_PAREN", "Expect '(' before function arguments.");
      ignoreNewlines();
      expr = finishCall(expr, _method);
    elseif match("LEFT_PAREN") then
      if not expr._accessable then
        error(makeError(previous(), "Expression cannot be indexed."));
      end
      ignoreNewlines();
      expr = finishCall(expr, nullptr);
    else
      do break end;
    end
  end
  do return expr end
end;
finishCall = function(expr, _method)
  local p = Expr.Call();
  p.line[ 1 ] = previous().line;
  p.parent = expr;
  p.method = _method;
  if not check("RIGHT_PAREN") then
    repeat
      ignoreNewlines();
      table.insert(p.arguments, expression());
    until not match("COMMA");
  end
  p.line[ 2 ] = previous().line;
  ignoreNewlines();
  consume("RIGHT_PAREN", "Expect ')' after arguments.");
  do return p end
end;
local literal = {
  FALSE = true,
  TRUE = true,
  NIL = true,
  NUMBER = true,
  STRING = true
};
primary = function()
  if literal[ peek().type ] then
    advance();
    do return Expr.Literal(previous()) end
  end
  if match("IDENTIFIER") then
    do return Expr.Variable(previous()) end
  end
  if match("DOT_DOT_DOT") then
    do return Expr.Dddot(previous()) end
  end
  if match("LEFT_PAREN") then
    ignoreNewlines();
    local expr = expression();
    ignoreNewlines();
    consume("RIGHT_PAREN", "Expect ')' after expression.");
    do return Expr.Grouping(expr) end
  end
  if match("LEFT_BRACE") then
    ignoreNewlines();
    do return tableConstructor() end
  end
  if match("FUNCTION", "METHOD", "AT") then
    do return functionConstructor(previous().type) end
  end
  if peek().keyword then
    error(makeError(peek(), "Keywords cannot be used as variable names."));
  end
  error(makeError(previous(), "Expect expression."));
end;
functionConstructor = function(type)
  local p = Expr.Function();
  p.line[ 1 ] = previous().line;
  p.method = type == "METHOD";
  if type ~= "AT" then
    consume("LEFT_PAREN", "Expect '('.");
    ignoreNewlines();
    while not check("RIGHT_PAREN") and not check("DOT_DOT_DOT") do
      local token = consume("IDENTIFIER", "Expect identifier as function parameter");
      table.insert(p.parameters, token);
      if match("EQUAL") then
        ignoreNewlines();
        local default = expression();
        table.insert(p.defaults, default);
      else
        table.insert(p.defaults, NULL);
      end
      if not match("COMMA") then
        do break end;
      end
      ignoreNewlines();
    end
    if match("DOT_DOT_DOT") then
      p.vararg = true;
    end
    ignoreNewlines();
    consume("RIGHT_PAREN", "Expect ')'.");
  end
  p.line[ 2 ] = previous().line;
  ignoreNewlines();
  p.body = flagBlockasBody(declaration());
  do return p end
end;
tableConstructor = function()
  ignoreNewlines();
  local p = Expr.TableConstructor();
  p.line = {
    previous().line,
    previous().line
  };
  local canBeComprehension = true;
  local isComprehension = false;
  if match("QUESTION") then
    consume("COMMA", "Expect ',' after '?' in table comprehension");
    ignoreNewlines();
    local expr = expression();
    if getmetatable(expr) ~= Expr.Call then
      error(makeError(previous(), "The value for the '?' form of a table comprehension must be a function or method call"));
    end
    do return tableComprehension("?", expr) end
  end
  while not check("RIGHT_BRACE") do
    local entry = {};
    if match("LEFT_BRACKET") then
      canBeComprehension = false;
      ignoreNewlines();
      entry.key = expression();
      ignoreNewlines();
      consume("RIGHT_BRACKET", "Expect ']' after key.");
      consume("EQUAL", "Expect '=' after [key].");
      ignoreNewlines();
      entry.value = expression();
    elseif peek().keyword then
      local t = peekNext(1);
      if t and t.type == "EQUAL" then
        canBeComprehension = false;
        entry.name = advance();
        advance();
        ignoreNewlines();
        entry.value = expression();
      else
        entry.value = expression();
      end
    else
      local expr = expression();
      if getmetatable(expr) == Expr.Variable and match("EQUAL") then
        ignoreNewlines();
        canBeComprehension = false;
        entry.name = expr.name;
        entry.value = expression();
      else
        entry.value = expr;
      end
    end
    table.insert(p.entries, entry);
    if canBeComprehension then
      local size = #p.entries;
      if size == 1 then
        if checkAfterNewlines("FOR") then
          isComprehension = true;
        elseif not check("COMMA") then
          canBeComprehension = false;
        end
      elseif size == 2 then
        local res = checkAfterNewlines("FOR");
        isComprehension = res;
        canBeComprehension = res;
      end
      if isComprehension then
        do break end;
      end
    end
    if not match("COMMA", "NEWLINE") then
      do break end;
    end
    ignoreNewlines();
  end
  if isComprehension then
    local entries = p.entries;
    do return tableComprehension(entries[ 1 ].value, #entries > 1 and entries[ 2 ].value or nil) end
  end
  ignoreNewlines();
  consume("RIGHT_BRACE", "Expect '}' at the end of table constructor.");
  do return p end
end;
tableComprehension = function(expr1, expr2)
  local p = Expr.TableComprehension();
  if expr1 == "?" then
    p.type = "HASH_SINGLE";
    p.value = expr2;
  elseif expr2 then
    p.type = "HASH";
    p.key = expr1;
    p.value = expr2;
  else
    p.type = "ARRAY";
    p.value = expr1;
  end
  ignoreNewlines();
  while match("FOR") do
    local loop = {};
    table.insert(p.forLoops, loop);
    loop.stmt = forStatement(true);
    if match("IF") then
      ignoreNewlines();
      loop.condition = expression();
    end
    ignoreNewlines();
  end
  consume("RIGHT_BRACE", "Expect '}' at the end of table comprehension.");
  do return p end
end;
