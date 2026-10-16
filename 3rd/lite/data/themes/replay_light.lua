-- replay_light.lua - our light theme (the main menu's Theme: light).
-- lite's default dark theme turned over: the same teal / cyan for the
-- caret, links and "+" actions, the same hues for code, darkened to read
-- on a light background. The node graph has a light canvas to match
-- (plugins/nodegraph/theme.lua: T.set_light).
local style = require "core.style"
local common = require "core.common"

style.background = { common.color "#dfe0e2" }      -- code
style.background2 = { common.color "#cbcbcc" }     -- side bars: the tree, the bar
style.background3 = { common.color "#ffffff" }     -- popups, drop-downs, tooltips
style.text = { common.color "#5b5f68" }
style.caret = { common.color "#0b97b0" }           -- teal / cyan, as in the dark one (#93ddfa), darker
style.accent = { common.color "#2b2f36" }          -- the brightest text (dark: near white) is the darkest here (not black: softer)
style.dim = { common.color "#a3a7af" }
style.divider = { common.color "#dcdee2" }
style.selection = { common.color "#bfe5ee" }
style.line_number = { common.color "#b9bcc3" }
style.line_number2 = { common.color "#6b6f79" }
style.line_highlight = { common.color "#e5e8eb" }
style.scrollbar = { common.color "#d3d6db" }
style.scrollbar2 = { common.color "#b2b6bd" }
style.warn = { common.color "#a65e08" }            -- (amber, darkened: yellows don't read on white)
style.error = { common.color "#c8323f" }
style.pane_divider = { common.color "#c4e2e8" }    -- a split you can drag (core/node.lua)
style.pane_divider_hover = { common.color "#7cc8d6" }
style.pane_divider_drag = { common.color "#1aa6c0" }

-- code: the plain text (names, brackets) a soft slate, so the colours are
-- what stands out (keywords, numbers, strings, operators); strings green,
-- not yellow (no yellow reads on white)
style.syntax["normal"] = { common.color "#4f545d" }
style.syntax["symbol"] = { common.color "#4f545d" }
style.syntax["comment"] = { common.color "#878d96" }
style.syntax["keyword"] = { common.color "#a8318f" }
style.syntax["keyword2"] = { common.color "#c83a50" }
style.syntax["number"] = { common.color "#b8460b" }
style.syntax["literal"] = { common.color "#b8460b" }
style.syntax["string"] = { common.color "#2e8540" }
style.syntax["operator"] = { common.color "#0a8199" }
style.syntax["function"] = { common.color "#0a8199" }
