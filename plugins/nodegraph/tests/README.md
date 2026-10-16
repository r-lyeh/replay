# tests/ — node graph samples

Small Lua files, one case each, to open as node graphs (right-click the
tab, or the icon on its left) and check by eye. Each file starts with what
the graph should show. They're plain Lua, not worlds: open them in the
editor, don't run them.

`runtime/tests/tests.lua` also lays every one of them out headless (no
overlaps, wires join the right pins) and moves every node of them like a
drag would (`runtime/tests/nodegraph_moves.lua`; run it alone to check all
of games/ too), so a broken case shows up there too.

for-00, for-01 · for-each-00, for-each-01 · while-00 · repeat-00 ·
if-00, if-else-00, if-elseif-00, if-nested-00 · call-00 · table-00 ·
class-00 · function-00 · types-00 · goto-00 · float-00 · move-00

**playground.lua**: every kind of node in one file, to look at them together.
