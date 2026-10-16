-- keys: input for the game. A long ESC press (hold it half a second)
-- toggles the title. Every key arrives here while playing ("a", "f1"...).
return { on_key = function(w, key, down)
  if key == "escape" and down then
    local t = w:node("/objects/title").c
    t.text = t.text == "ESC!" and "hello, tree world" or "ESC!"
  end
end }
