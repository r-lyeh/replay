# sfxr

A sound effect editor: `.sfx` files, made the way DrPetter's
[sfxr](https://www.drpetter.se/project_sfxr.html) makes them (MIT, © 2007
Tomas Pettersson: its notice is in `runtime/sfxr.lua`). Its synth and its generators are ported to Lua in `runtime/sfxr.lua`, line
by line from the original C++ (`ResetParams`, `ResetSample`, `SynthSample`,
the seven buttons, Randomize, Mutate).

- `synth.lua`: the synth, which is `runtime/sfxr.lua` (no Lite in it: games play the
  same sounds: `w:sound("jump")` plays `assets/jump.sfx`)
- `editor.lua`: the tab (runs in Lite)
- `files.lua`: the extensions it opens (`sfx`)
- `config.lua`: `autoplay` (every change plays it), `gain` (4: the original's
  WAV export loudness; 1: its live playback)
- `templates/sound.sfx`: what `New sound` in the tree's `/assets` makes
- `samples/*.sfx`: one of each kind (coin, laser, explosion, powerup, hit,
  jump, blip)

In a tab: the generators on the left (each click a new one of that kind;
Mutate nudges this one, Randomize makes anything), the wave and the
sliders on the right (grouped as the original: envelope, frequency,
vibrato, arpeggio, duty, retrigger, phaser, filters), the sound drawn in
the middle with a playhead. SPACE or a click on the sound plays it;
releasing a slider plays it. Double-click a slider: its default. SHIFT
drags finely; CTRL+wheel nudges. CTRL+Z / CTRL+Y undo and redo, CTRL+S
saves, *Export .wav* writes `<name>.wav` beside it (44100 Hz, 16-bit, mono).

A `.sfx` file is Lua data: `return { wave = 0, base_freq = 0.3, ... }`
(the original's parameter names without `p_`; `wave`: 0 square, 1 sawtooth,
2 sine, 3 noise). Sound goes out through the editor (`host_audio_play`,
editor/editor.c). Not yet: playing them in a game (the synth is ready for it).
