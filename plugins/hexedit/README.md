# hexedit

A hex editor: inspect, find, replace and change the bytes of any file, of
any size. The file is read off disk in chunks (`chunk_kib`, 1 MiB; eight
kept, the least used dropped), so a file of gigabytes opens at once and
scrolls as fast as a small one; finding and replacing stream through it in
the background (the status shows how far; ESC stops).

- `hexfile.lua`: the model (chunks, edits, find, replace; no Lite in it)
- `editor.lua`: the tab (runs in Lite)
- `files.lua`: the extensions it opens (bin, dat, rom, sav, img, iso, exe,
  dll, ...); any other file: its tab's right-click menu, **Open tab with > Hex editor**, or
  the command palette's *Hexedit: Open File*
- `config.lua`: `columns` (16), `chunk_kib` (1024), `big_endian` (the values)

In a tab: the offset, the bytes in hex, the same as text. Click a byte or
move with the arrows (PAGE UP / DOWN, HOME / END, CTRL+HOME / END; SHIFT:
select). Type hex digits on the hex side, characters on the text side
(TAB switches): the edits show lit, kept aside until **CTRL+S** writes them
in place (only those bytes: fast on any size). CTRL+Z undoes an edit.
CTRL+F finds (`DE AD BE EF`, `deadbeef`, or text; `"quoted"` for text that
looks like hex), F3 / SHIFT+F3 the next / the one before. CTRL+R replaces
all: the same length, as edits; another length writes the file again
(streamed to a copy beside it, then put in its place). CTRL+G goes to an
offset (`0x1F00`, `1F00h`, `8000`, `+16`, `-16`). CTRL+C copies the
selection (hex, or text from the text side). Under the bytes: the value at
the cursor as u8, i8, u16, i16, u32, i32, f32, f64. The scrollbar on the
right drags through the whole file.
