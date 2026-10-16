-- .dialog files (runtime/dialog.lua, plugins/dialog): a character's lines --< Replay
local syntax = require "core.syntax"

syntax.add {
  files = { "%.dialog$" },
  comment = "//",
  patterns = {
    { pattern = "//.-\n",               type = "comment"  },
    { pattern = "^%-%-+%s*\n",          type = "comment"  },   -- a break between scenes
    { pattern = "^%d+",                 type = "number"   },   -- the line's number
    { pattern = "^#[%a_][%w_]*",        type = "keyword2" },   -- a topic's line
    { pattern = "%->%s*%d+",            type = "keyword"  },   -- then that line
    { pattern = "%[[%d%s,]*%]",         type = "keyword"  },   -- the player picks one of these
    { pattern = "#[%a_][%w_]*",         type = "function" },   -- a topic mentioned
    { pattern = ":[%a_][%w_]*:",        type = "string"   },   -- an emote
    { pattern = "{[^}]*}",              type = "operator" },   -- a pause
  },
  symbols = {},
}
