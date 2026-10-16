local _hurdytemp0
local path = (...):gsub("[^%.]*$", "");
local M = require(path .. "main");
require(path .. "error");
require(path .. "parser");
_hurdytemp0 = M
local Error = _hurdytemp0.Error
local Stmt = _hurdytemp0.Stmt
local Expr = _hurdytemp0.Expr
local NULL = _hurdytemp0.NULL
_hurdytemp0 = nil
local visit = {};
local showLineComments, buildLineMap, lua, lineMap, indent, currentLine;
local compile, addLine, setLineMapStart, setLineMapEnd, addLua, addSemicolon, beginContinue, endContinue, getIndent;
M.compile = function(statements, _showLineComments, _buildLineMap)
  if _showLineComments == nil then _showLineComments = true end
  if _buildLineMap == nil then _buildLineMap = true end
  showLineComments = _showLineComments;
  buildLineMap = _buildLineMap;
  lua = {};
  lineMap = {};
  indent = 0;
  currentLine = {
    0,
    0
  };
  addLua("local _hurdytemp0\n");
  for _, stmt in ipairs(statements) do
    compile(stmt, true);
  end
  do return table.concat(lua), (buildLineMap and lineMap or nil) end
end;
compile = function(t, addNewline)
  if addNewline == nil then addNewline = true end
  local mt = getmetatable(t);
  local f = visit[ mt ](t);
  if mt.__type == "expression" then
    do return end
  end
  if addNewline and (mt ~= Stmt.Var or t["local"] or #t.initializers > 0) then
    addLine();
  end
end;
addLine = function()
  if showLineComments or buildLineMap then
    local currentLine = currentLine;
    local a, b = currentLine[ 1 ], currentLine[ 2 ];
    local s = a ~= b and string.format("%s-%s", a, b) or tostring(a);
    if buildLineMap then
      table.insert(lineMap, s);
    end
    if showLineComments then
      addLua(string.format(" --[[%s]]", s));
    end
  end
  addLua("\n");
  addLua(getIndent());
end;
setLineMapStart = function(i)
  currentLine[ 1 ] = i;
end;
setLineMapEnd = function(i)
  currentLine[ 2 ] = i;
end;
addLua = function(s)
  table.insert(lua, s);
end;
addSemicolon = function(s)
  table.insert(lua, ";");
end;
beginContinue = function(stmt)
  if stmt.hasContinue then
    addLua("do");
    indent = indent + (1);
    addLine();
  end
end;
endContinue = function(stmt)
  if stmt.hasContinue then
    indent = indent - (1);
    addLine();
    addLua("end");
    addLine();
    addLua("::continue::");
    addSemicolon();
  end
end;
getIndent = function()
  do return string.rep(" ", 2 * indent) end
end;
visit[ Stmt.Expression ] = function(stmt)
  setLineMapStart(stmt.expression.line[ 1 ]);
  setLineMapEnd(stmt.expression.line[ 2 ]);
  compile(stmt.expression);
  addSemicolon();
end;
visit[ Stmt.Var ] = function(stmt)
  setLineMapStart(stmt.names[ 1 ].line);
  setLineMapEnd(stmt.names[ #stmt.names ].line);
  if stmt["local"] and stmt.functionDeclaration then
    addLua("local ");
    addLua(stmt.names[ 1 ].text);
    addSemicolon();
    addLine();
    setLineMapStart(stmt.initializers[ 1 ].line[ 1 ]);
    setLineMapEnd(stmt.initializers[ 1 ].line[ 2 ]);
    addLua(stmt.names[ 1 ].text);
    addLua(" = ");
    compile(stmt.initializers[ 1 ]);
    addSemicolon();
    do return end
  end
  if stmt["local"] or #stmt.initializers > 0 then
    if stmt["local"] then
      addLua("local ");
    end
    for i, name in ipairs(stmt.names) do
      addLua(name.text);
      if i ~= #stmt.names then
        addLua(", ");
      end
    end
    if #stmt.initializers > 0 then
      addLua(" = ");
      setLineMapStart(stmt.initializers[ 1 ].line[ 1 ]);
      setLineMapEnd(stmt.initializers[ #stmt.initializers ].line[ 2 ]);
      for i, expr in ipairs(stmt.initializers) do
        compile(expr);
        if i ~= #stmt.initializers then
          addLua(", ");
        end
      end
    end
    addSemicolon();
  end
end;
visit[ Stmt.Block ] = function(stmt)
  if not stmt.bodyOfOther then
    addLua("do");
    setLineMapStart(0);
    setLineMapEnd(0);
    indent = indent + (1);
    addLine();
  end
  for i, subStmt in ipairs(stmt.statements) do
    compile(subStmt, false);
    if i ~= #stmt.statements then
      addLine();
    end
  end
  if not stmt.bodyOfOther then
    indent = indent - (1);
    addLine();
    setLineMapStart(0);
    setLineMapEnd(0);
    addLua("end");
  end
end;
visit[ Stmt.If ] = function(stmt)
  setLineMapStart(stmt.ifData.condition.line[ 1 ]);
  setLineMapEnd(stmt.ifData.condition.line[ 2 ]);
  do
    local t = stmt.ifData.identifier
    if t then
      local name = t.text;
      addLua("do");
      indent = indent + (1);
      addLine();
      addLua("local ");
      addLua(name);
      addLua(" = ");
      compile(stmt.ifData.condition);
      addLine();
      addLua("if ");
      addLua(name);
    else
      addLua("if ");
      compile(stmt.ifData.condition);
    end
  end
  addLua(" then");
  indent = indent + (1);
  addLine();
  compile(stmt.ifData.branch, false);
  indent = indent - (1);
  addLine();
  local numNesting = 0;
  for i, data in ipairs(stmt.elseifData) do
    setLineMapStart(data.condition.line[ 1 ]);
    setLineMapEnd(data.condition.line[ 2 ]);
    do
      local t = data.identifier
      if t then
        numNesting = numNesting + (1);
        local name = t.text;
        addLua("else");
        indent = indent + (1);
        addLine();
        addLua("local ");
        addLua(name);
        addLua(" = ");
        compile(data.condition);
        addLine();
        addLua("if ");
        addLua(name);
      else
        addLua("elseif ");
        compile(data.condition);
      end
    end
    addLua(" then");
    indent = indent + (1);
    addLine();
    compile(data.branch, false);
    indent = indent - (1);
    addLine();
  end
  if stmt.elseBranch then
    addLua("else");
    setLineMapStart(0);
    setLineMapEnd(0);
    indent = indent + (1);
    addLine();
    compile(stmt.elseBranch, false);
    indent = indent - (1);
    addLine();
  end
  setLineMapStart(0);
  setLineMapEnd(0);
  for i = 1, numNesting do
    addLua("end");
    indent = indent - (1);
    addLine();
  end
  addLua("end");
  if (stmt.ifData.identifier) then
    indent = indent - (1);
    addLine();
    addLua("end");
  end
end;
visit[ Stmt.While ] = function(stmt)
  addLua("while ");
  setLineMapStart(stmt.condition.line[ 1 ]);
  setLineMapEnd(stmt.condition.line[ 2 ]);
  compile(stmt.condition);
  addLua(" do");
  indent = indent + (1);
  addLine();
  beginContinue(stmt);
  compile(stmt.body, false);
  endContinue(stmt);
  indent = indent - (1);
  addLine();
  setLineMapStart(0);
  setLineMapEnd(0);
  addLua("end");
end;
visit[ Stmt.ForNumeric ] = function(stmt)
  addLua("for ");
  addLua(stmt.identifier.text);
  addLua(" = ");
  setLineMapStart(stmt.initialValue.line[ 1 ]);
  setLineMapEnd(stmt.limit.line[ 2 ]);
  compile(stmt.initialValue);
  addLua(", ");
  compile(stmt.limit);
  if stmt.step then
    setLineMapEnd(stmt.step.line[ 2 ]);
    addLua(", ");
    compile(stmt.step);
  end
  addLua(" do");
  indent = indent + (1);
  addLine();
  setLineMapStart(0);
  setLineMapEnd(0);
  beginContinue(stmt);
  compile(stmt.body, false);
  endContinue(stmt);
  indent = indent - (1);
  addLine();
  setLineMapStart(0);
  setLineMapEnd(0);
  addLua("end");
end;
visit[ Stmt.ForGeneric ] = function(stmt)
  addLua("for ");
  for i, name in ipairs(stmt.namelist) do
    addLua(name.text);
    if i ~= #stmt.namelist then
      addLua(", ");
    end
  end
  addLua(" in ");
  setLineMapStart(stmt.explist[ 1 ].line[ 1 ]);
  setLineMapEnd(stmt.explist[ #stmt.explist ].line[ 2 ]);
  for i, expr in ipairs(stmt.explist) do
    compile(expr);
    if i ~= #stmt.explist then
      addLua(", ");
    end
  end
  addLua(" do");
  indent = indent + (1);
  addLine();
  beginContinue(stmt);
  compile(stmt.body, false);
  endContinue(stmt);
  indent = indent - (1);
  addLine();
  setLineMapStart(0);
  setLineMapEnd(0);
  addLua("end");
end;
visit[ Stmt.Return ] = function(stmt)
  setLineMapStart(#stmt.values == 0 and 0 or stmt.values[ 1 ].line[ 1 ]);
  setLineMapEnd(#stmt.values == 0 and 0 or stmt.values[ #stmt.values ].line[ 2 ]);
  addLua(#stmt.values == 0 and "do return" or "do return ");
  for i, expr in ipairs(stmt.values) do
    compile(expr);
    if i ~= #stmt.values then
      addLua(", ");
    end
  end
  addLua(" end");
end;
visit[ Stmt.Assign ] = function(stmt)
  setLineMapStart(stmt.names[ 1 ].line[ 1 ]);
  setLineMapEnd(stmt.values[ #stmt.values ].line[ 2 ]);
  for i, expr in ipairs(stmt.names) do
    compile(expr);
    if i ~= #stmt.names then
      addLua(", ");
    end
  end
  addLua(" = ");
  for i, expr in ipairs(stmt.values) do
    compile(expr);
    if i ~= #stmt.values then
      addLua(", ");
    end
  end
  addSemicolon();
end;
local opString = {
  [ "DOT_DOT_EQ" ] = "..",
  [ "MINUS_EQ" ] = "-",
  [ "PLUS_EQ" ] = "+",
  [ "SLASH_EQ" ] = "/",
  [ "SLASH_SLASH_EQ" ] = "//",
  [ "STAR_EQ" ] = "*",
  [ "STAR_STAR_EQ" ] = "^",
  [ "CARET_EQ" ] = "~",
  [ "PERCENT_EQ" ] = "%",
  [ "GT_GT_EQ" ] = ">>",
  [ "LT_LT_EQ" ] = "<<",
  [ "AMP_EQ" ] = "&",
  [ "PIPE_EQ" ] = "|",
  [ "AND_EQ" ] = "and",
  [ "OR_EQ" ] = "or"
};
local opAssignCompileTarget;
opAssignCompileTarget = function(expr, cacheKey)
  addLua("_hurdytemp1");
  do
    local name = expr.name
    if name then
      if name.keyword ~= "LUA" then
        addLua(".");
        addLua(name.text);
      else
        addLua("[\"");
        addLua(name.text);
        addLua("\"]");
      end
    else
      addLua("[ ");
      if cacheKey then
        addLua("_hurdytemp2");
      else
        compile(expr.key);
      end
      addLua(" ]");
    end
  end
end;
visit[ Stmt.OpAssign ] = function(stmt)
  setLineMapStart(stmt.name.line[ 1 ]);
  setLineMapEnd(stmt.value.line[ 2 ]);
  local p = getmetatable(stmt.name) == Expr.Access and stmt.name;
  local cacheKey = p and p.key ~= nil and getmetatable(p.key) ~= Expr.Literal;   -- Replay fix: a.b += 1 (no key expr) crashed
  if p then
    addLua("do");
    indent = indent + (1);
    addLine();
    addLua("local _hurdytemp1 = ");
    compile(p.parent);
    addLine();
    if cacheKey then
      addLua("local _hurdytemp2 = ");
      compile(p.key);
      addLine();
    end
    opAssignCompileTarget(p, cacheKey);
  else
    compile(stmt.name);
  end
  addLua(" = ");
  if p then
    opAssignCompileTarget(p, cacheKey);
  else
    compile(stmt.name);
  end
  addLua(" ");
  do
    local s = opString[ stmt.op.type ]
    if s then
      addLua(s);
    else
      error(Error(stmt.op.line, stmt.op.character, stmt.op.text, "Undefined assignment operator"));
    end
  end
  addLua(" (");
  compile(stmt.value);
  addLua(")");
  if p then
    indent = indent - (1);
    addLine();
    addLua("end");
  else
    addSemicolon();
  end
end;
visit[ Stmt.Break ] = function(stmt)
  setLineMapStart(stmt.token.line);
  setLineMapEnd(stmt.token.line);
  addLua("do break end");
  addSemicolon();
end;
visit[ Stmt.Import ] = function(stmt)
  setLineMapStart(0);
  setLineMapEnd(0);
  addLua("_hurdytemp0 = ");
  compile(stmt.from);
  addLine();
  for _, entry in ipairs(stmt.data) do
    addLua("local ");
    addLua(entry.as.text);
    addLua(" = _hurdytemp0");
    if entry.name.keyword == "LUA" then
      addLua("[\"");
      addLua(entry.name.text);
      addLua("\"]");
    else
      addLua(".");
      addLua(entry.name.text);
    end
    addLine();
  end
  addLua("_hurdytemp0 = nil");
end;
visit[ Stmt.Repeat ] = function(stmt)
  setLineMapStart(0);
  setLineMapEnd(0);
  addLua("repeat");
  indent = indent + (1);
  addLine();
  beginContinue(stmt);
  compile(stmt.body, false);
  endContinue(stmt);
  indent = indent - (1);
  addLine();
  addLua("until ");
  setLineMapStart(stmt.condition.line[ 1 ]);
  setLineMapEnd(stmt.condition.line[ 2 ]);
  compile(stmt.condition);
  addSemicolon();
end;
visit[ Stmt.Continue ] = function(stmt)
  setLineMapStart(stmt.token.line);
  setLineMapEnd(stmt.token.line);
  addLua("goto continue");
  addSemicolon();
end;
visit[ Expr.Binary ] = function(expr)
  compile(expr.left);
  addLua(" ");
  local type = expr.op.type;
  if type == "BANG_EQ" then
    addLua("~=");
  elseif type == "STAR_STAR" then
    addLua("^");
  elseif type == "CARET" then
    addLua("~");
  else
    addLua(expr.op.text);
  end
  addLua(" ");
  compile(expr.right);
end;
visit[ Expr.Grouping ] = function(expr)
  addLua("(");
  compile(expr.expression);
  addLua(")");
end;
_hurdytemp0 = math
local floor = _hurdytemp0.floor
_hurdytemp0 = nil
local utf8Bytes = {
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0
};
local processUtf8;
processUtf8 = function(codePoint)
  local bytes = utf8Bytes;
  local numBytes = 1;
  if codePoint < 0x80 then
    bytes[ numBytes ] = codePoint;
  else
    local maxBits = 6;
    repeat
      bytes[ numBytes ] = 0x80 + (codePoint % 64);
      codePoint = floor(codePoint / 64);
      maxBits = maxBits - (1);
      numBytes = numBytes + (1);
    until codePoint < 2 ^ maxBits;
    bytes[ numBytes ] = codePoint + 256 - 2 ^ (maxBits + 1);
  end
  for i = numBytes, 1, -1 do
    addLua(string.format("\\%.3u", bytes[ i ]));
  end
end;
visit[ Expr.Literal ] = function(expr)
  local token = expr.value;
  do
    local escapes = token.escapes
    if escapes then
      local text = token.text;
      local start = 1;
      for _, escape in ipairs(escapes) do
        addLua(text:sub(start, escape.start - 1));
        local type = escape.type;
        if type == "HEX" then
          addLua(string.format("\\%.3u", escape.character));
        elseif type == "CODEPOINT" then
          processUtf8(escape.character);
        end
        start = escape["end"];
      end
      addLua(text:sub(start));
    else
      addLua(token.text);
    end
  end
end;
visit[ Expr.Unary ] = function(expr)
  addLua(expr.op.type == "BANG" and "not " or expr.op.text);
  compile(expr.expression);
end;
visit[ Expr.Variable ] = function(expr)
  addLua(expr.name.text);
end;
visit[ Expr.Access ] = function(expr)
  compile(expr.parent);
  do
    local name = expr.name
    if name then
      if name.keyword == "LUA" then
        addLua('["');
        addLua(name.text);
        addLua('"]');
      else
        addLua(".");
        addLua(name.text);
      end
    else
      addLua("[ ");
      compile(expr.key);
      addLua(" ]");
    end
  end
end;
visit[ Expr.Call ] = function(expr)
  compile(expr.parent);
  do
    local t = expr.method
    if t then
      addLua(":");
      addLua(t.text);
    end
  end
  addLua("(");
  for i, arg in ipairs(expr.arguments) do
    compile(arg);
    if i ~= #expr.arguments then
      addLua(", ");
    end
  end
  addLua(")");
end;
visit[ Expr.Function ] = function(expr)
  addLua("function(");
  if expr.method then
    addLua("self");
    if #expr.parameters > 0 or expr.vararg then
      addLua(", ");
    end
  end
  for i, token in ipairs(expr.parameters) do
    addLua(token.text);
    if i ~= #expr.parameters or expr.vararg then
      addLua(", ");
    end
  end
  if expr.vararg then
    addLua("...");
  end
  addLua(")");
  setLineMapEnd(expr.line[ 2 ]);
  indent = indent + (1);
  addLine();
  for i = 1, #expr.parameters do
    local p = expr.defaults[ i ];
    local name = expr.parameters[ i ].text;
    if p ~= NULL then
      setLineMapStart(p.line[ 1 ]);
      setLineMapEnd(p.line[ 1 ]);
      addLua("if ");
      addLua(name);
      addLua(" == nil then ");
      addLua(name);
      addLua(" = ");
      compile(p);
      addLua(" end");
      addLine();
    end
  end
  compile(expr.body, false);
  indent = indent - (1);
  addLine();
  setLineMapStart(0);
  setLineMapEnd(0);
  addLua("end");
end;
visit[ Expr.TableConstructor ] = function(expr)
  addLua("{");
  indent = indent + (1);
  for i, entry in ipairs(expr.entries) do
    addLine();
    local name = entry.name;
    local key = entry.key;
    local value = entry.value;
    setLineMapEnd(value.line[ 2 ]);
    if name then
      if name.keyword == "LUA" then
        addLua('["');
        addLua(name.text);
        addLua('"]');
      else
        addLua(name.text);
      end
      addLua(" = ");
      setLineMapStart(value.line[ 1 ]);
    elseif key then
      setLineMapStart(key.line[ 1 ]);
      addLua("[ ");
      compile(key);
      addLua(" ] = ");
    end
    compile(value);
    if i ~= #expr.entries then
      addLua(",");
    end
  end
  indent = indent - (1);
  if #expr.entries > 0 then
    addLine();
  end
  addLua("}");
end;
visit[ Expr.TableComprehension ] = function(expr)
  addLua("(function()");
  indent = indent + (1);
  addLine();
  addLua("local _hurdytemp1 = {}");
  addLine();
  if (expr.type == "ARRAY") then
    addLua("local _hurdytemp2 = 0");
    addLine();
  end
  for _, loop in ipairs(expr.forLoops) do
    addLua("for ");
    local stmt = loop.stmt;
    if getmetatable(stmt) == Stmt.ForNumeric then
      addLua(stmt.identifier.text);
      addLua(" = ");
      setLineMapStart(stmt.initialValue.line[ 1 ]);
      setLineMapEnd(stmt.limit.line[ 2 ]);
      compile(stmt.initialValue);
      addLua(", ");
      compile(stmt.limit);
      if stmt.step then
        setLineMapEnd(stmt.step.line[ 2 ]);
        addLua(", ");
        compile(stmt.step);
      end
    else
      for i, name in ipairs(stmt.namelist) do
        addLua(name.text);
        if i ~= #stmt.namelist then
          addLua(", ");
        end
      end
      addLua(" in ");
      setLineMapStart(stmt.explist[ 1 ].line[ 1 ]);
      setLineMapEnd(stmt.explist[ #stmt.explist ].line[ 2 ]);
      for i, expr in ipairs(stmt.explist) do
        compile(expr);
        if i ~= #stmt.explist then
          addLua(", ");
        end
      end
    end
    addLua(" do");
    indent = indent + (1);
    addLine();
    do
      local cond = loop.condition
      if cond then
        addLua("if ");
        compile(cond);
        addLua(" then");
        indent = indent + (1);
        addLine();
      end
    end
  end
  local type = expr.type;
  if type == "ARRAY" then
    addLua("_hurdytemp2 = _hurdytemp2 + 1");
    addLine();
    addLua("_hurdytemp1[_hurdytemp2] = ");
    setLineMapStart(expr.value.line[ 1 ]);
    setLineMapEnd(expr.value.line[ 1 ]);
    compile(expr.value);
  elseif type == "HASH" then
    addLua("_hurdytemp1[ ");
    setLineMapStart(expr.key.line[ 1 ]);
    setLineMapEnd(expr.key.line[ 1 ]);
    compile(expr.key);
    addLua(" ] = ");
    setLineMapStart(expr.value.line[ 1 ]);
    setLineMapEnd(expr.value.line[ 1 ]);
    compile(expr.value);
  else
    addLua("local _hurdytemp2, _hurdytemp3 = ");
    setLineMapStart(expr.value.line[ 1 ]);
    setLineMapEnd(expr.value.line[ 1 ]);
    compile(expr.value);
    addLine();
    addLua("_hurdytemp1[_hurdytemp2] = _hurdytemp3");
  end
  for _, loop in ipairs(expr.forLoops) do
    if loop.condition then
      indent = indent - (1);
      addLine();
      addLua("end");
    end
    indent = indent - (1);
    addLine();
    addLua("end");
  end
  addLine();
  setLineMapStart(0);
  setLineMapEnd(0);
  addLua("return _hurdytemp1");
  indent = indent - (1);
  addLine();
  addLua("end)()");
end;
visit[ Expr.Dddot ] = function(expr)
  addLua(expr.token.text);
end;
