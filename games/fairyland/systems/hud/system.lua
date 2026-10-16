-- hud: the prompt near the fairy, what's carried, the dialog box (her line,
-- typed out, wrapped; the answers to choose from) and her emote
return function(w, dt)
  local st, rl = w:node("/data/state"), w:node("/data/rules")
  if not (st and rl) then return end
  local talk, walk = st.c.talk, st.c.walk
  local d = w:dialog(rl.c.room.dialog)
  local prompt, box = w:node("/objects/hud/prompt"), w:node("/objects/hud/box")
  prompt.c.text[1] = (talk.near and not talk.on) and "SPACE / A: talk" or ""
  w:node("/objects/hud/carry").c.text[1] = walk.carrying and ("carrying: " .. walk.carrying) or ""
  box.c.hidden = not talk.on
  local EMOTES = { grin = "^o^", fear = "!!", angry = "#!", sad = ";_;", love = "<3" }
  w:node("/objects/fairy/emote").c.text[1] = talk.on and talk.emote and (EMOTES[talk.emote] or (":" .. talk.emote .. ":")) or ""
  if not (talk.on and d) then return end
  local lines, cur = {}, ""                        -- wrapped at 30 letters (the left part of the box)
  local said = talk.at == "?" and "Anything else?" or d:typed(talk)   -- (the questions: about what you've heard of)
  for word in said:gmatch("%S+%s*") do
    if #cur + #word > 30 and cur ~= "" then lines[#lines + 1] = cur; cur = "" end
    cur = cur .. word
  end
  lines[#lines + 1] = cur
  for i = 1, 3 do w:node("/objects/hud/box/line" .. i).c.text[1] = lines[i] or "" end
  local ch = d:choices(talk)
  local typing = (talk.part or 1) <= #(d:line(talk) or { parts = {} }).parts
  for i = 1, 4 do
    local c = ch and not typing and ch[i]
    w:node("/objects/hud/box/choice" .. i).c.text[1] = c and ((i == talk.pick and "> " or "  ") .. c.text:sub(1, 26)) or ""
  end
end
