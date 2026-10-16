# Fairyland

A very small demo: a room drawn with the tilemap plugin (`assets/room.tmap`)
and a fairy to talk to, whose words are a `.dialog` file (`assets/fairy.dialog`,
the dialog plugin's sample): a first take on the dialog system, Animal
Crossing style.

- Arrows / WASD (a gamepad: dpad or left stick) walk; near the fairy,
  **Space** (or Enter, E, a pad's A) talks. Space goes on (or shows a line
  being typed all at once); up / down choose an answer.
- Her answers follow the file, a conversation (a scene, up to a `--`) per
  talk: the first time she asks if it's your first visit; talk again and
  she asks to be friends; then she just says *Oh hi*. Pick up the
  **bananas** (walk over them): at the end of a talk you can ask her *Tell
  me more about bananas* (her `#bananas` line answers).
- Edit `assets/fairy.dialog` while it plays: the next line said is the new
  one. Edit the room in the tilemap editor: its walls are solid at once.

How it's made: `systems/talk` runs the conversation with `w:dialog(name)`
(runtime/dialog.lua: the file parsed, and `d:begin`, `d:update`,
`d:advance`, `d:choices` to run it; its state, `/data/state: talk`, is
world data: it saves and rewinds); `systems/hud` draws the box.
