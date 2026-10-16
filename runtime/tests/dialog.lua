-- dialog.lua - runtime/dialog.lua: the sample parsed, a talk run through.
--   cd runtime/tests && luajit dialog.lua
package.path = "../?.lua;" .. package.path
local D = require "dialog"
local n, fails = 0, 0
local function check(c, m) n = n + 1; if not c then fails = fails + 1; print("  FAIL: " .. m) end end
local f = assert(io.open("../../plugins/dialog/sample.dialog", "rb"))
local d = setmetatable(D.parse(f:read("*a")), D.methods); f:close()
check(#d.errors == 0, "the sample parses clean")
check(d.start == 0 and #d.order == 15, "15 lines, from 0")
check(d.lines[0].choices[2] == 2 and d.lines[1].next == 3 and d.lines[14].next == nil, "choices and arrows")
check(d.topics.monster and d.topics.bananas, "two topics")
check(D.plain(d.lines[10].parts):match("^Great!") and d.lines[10].parts[2].emote == "grin", "an emote")
local st = {}
d:begin(st)
while d:update(st, 0.1, 40) do end
check(d:typed(st):match("first visit%?$"), "typed out")
check(#d:choices(st) == 2, "two answers")
st.pick = 2
check(d:advance(st) and st.at == 4, "the 2nd answer: line 4")
d:advance(st); check(st.at == 4, "a line being typed: the button shows it all first")
check(not d:advance(st) and st.done and st.start == 5, "4 -> 5 is past a `--`: the talk ends, the next starts at 5")
d:begin(st); check(st.at == 5, "the next talk: line 5")
d:finish(st); st.pick = 1; d:advance(st); check(st.at == 10, "yes: 10")
d:finish(st); check(st.emote == "grin", "her emote")
check(not d:advance(st) and st.start == 13, "10 -> 13 (the next scene): ends, next time from 13")
d:begin(st); check(st.at == 13, "the next talk: Oh hi")
d:finish(st); check(not d:advance(st) and st.start == 13, "13 -> 13: ends, and stays there")
st.known.bananas = true
d:begin(st); d:finish(st)
check(d:advance(st) and st.at == "?", "a topic known: then the player's questions")
local ch = d:choices(st)
check(#ch == 2 and ch[1].text == "Tell me more about bananas" and ch[2].bye, "about bananas, or bye")
st.pick = 1; d:advance(st); check(st.at == "#bananas", "the topic's line answers")
d:finish(st); check(st.emote == "angry", "with its emote")
check(d:advance(st) and st.at == "?", "then the questions again")
st.pick = 2; check(not d:advance(st) and st.done, "bye: the end")
do                                                 -- 12 -> 5 (back up): the talk ends; the next one starts at 5
  local d2 = setmetatable(D.parse(io.open("../../plugins/dialog/sample.dialog"):read("*a")), D.methods)
  local s2 = { start = 5 }
  d2:begin(s2); d2:finish(s2); s2.pick = 3          -- (8 Maybe -> 12)
  check(d2:advance(s2) and s2.at == 12, "Maybe -> 12")
  d2:finish(s2)
  check(not d2:advance(s2) and s2.done and s2.start == 5, "12 -> 5: back up, the talk ends")
  d2:begin(s2); check(s2.at == 5, "and the next talk starts at 5")
end
local bad = D.parse("0 hi -> 7\nnot a line\n")
check(#bad.errors == 2, "errors: a missing line, a bad one")
print(string.format("dialog: %s", fails == 0 and ("all ok (" .. n .. " checks)") or (fails .. " failed")))
