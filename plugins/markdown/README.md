# Markdown viewer

A plugin of Replay's editor (`plugins/markdown`): `.md` files open
**rendered**, in a tab of their own, instead of the text editor.

- `files.lua`: which extensions open here (`md`)
- `config.lua`: its settings (`size`, `width`, `zoom`)
- `editor.lua`: the viewer itself (runs in Lite, on the canvas)

## Using it

- The wheel scrolls; **CTRL+wheel** sizes the text, which flows again to
  the tab's width.
- A click on a link follows it: a `#heading` scrolls there, another `.md`
  shows in this same tab, any other file opens in its own tab (a folder:
  its `README.md`), a web address opens in the browser. **Backspace** goes
  back (to the file before, at the same place). Paths are read next to the
  file, else from a folder above it (`docs/PLUGINS.md` works from inside
  `docs/`) or the project's folder.
- Keys: up / down, page up / down, home / end.
- **Right-click**: back, text size, *Edit as text*, reload, copy path, the
  contents (a section per heading, its own headings in a submenu: type to
  find one); last, *Plugin: markdown*
  (its source, reload, settings).
- The file is read again when it changes on disk: edit it as text beside
  it and save.
- **F1** in the editor (or the main menu's *Help*) opens
  `docs/HELP.md` here.

## What it renders

The emoji the docs use (🎮 ✔️ ✅ 🧪 💤 🔜 💡) are pictures in `emoji/`, as tall
as the text (Lite's fonts have no emoji); `tools/make_emoji.py` draws them.
Others show as the font draws them (usually nothing).

| Markdown | Shown as |
|---|---|
| `#` .. `######` | headings (`#` and `##` underlined) |
| `**bold**`, `*italic*`, `` `code` `` | bold, coloured, code on a box |
| `[text](link)`, `<a href="link">` | a link; a web one has a small arrow after it |
| `![alt](image.png)`, `<img src="image.png" width="160">` | the image, its pixels at the text's zoom (`width`: that wide), never wider than the column; a web image: its alt text |
| `<br>` | a new line |
| `-` / `*` / `1.` lists | bullets and numbers, nested by indent |
| `- [x] done`, `- [ ] to do` | a ticked box, an empty one |
| `<p align="center">`, `<div align="center">`, `<center>` | their lines centred |
| `<h1>`..`<h6>` (`align="center"`) | headings |
| `<b>` `<strong>`, `<i>` `<em>`, `<code>` `<kbd>`, `<hr>` | bold, italic, code, a rule |
| fenced code | a box of monospace text |
| `>` quotes, `---` rules, tables | as you'd expect |

Other HTML tags are dropped, their text kept. It isn't CommonMark: enough for
the project's docs.
