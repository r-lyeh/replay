-- the conversation: where it is (runtime/dialog.lua runs it), what the player
-- knows (#topics) and has heard; `on`: talking now
return { on = false, start = nil, known = {}, heard = {}, pick = 1 }
