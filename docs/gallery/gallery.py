#!/usr/bin/env python3
# gallery.py - docs/gallery/: nine square pictures of the editor (320 x 320,
# crops of offscreen screenshots, never scaled), taken again each time this
# runs (they overwrite the last ones: 1.png .. 9.png, the order of
# SHOTS). docs/README.md shows them 3 x 3, by those names.
#
#   python3 docs/gallery/gallery.py EDITOR [OUT_DIR]
#     EDITOR: a built editor (play.exe / ./play); run from the repo's root.
#     Needs Pillow; an offscreen video driver where there's no display
#     (SDL_VIDEODRIVER=offscreen).
#
# A shot: (what it shows, the world it runs, its scene in scenes.lua or None:
# the game playing, frames to wait, the crop's top left x, y, more arguments).
import os, subprocess, sys, tempfile
from PIL import Image

SHOTS = [
    ("game",        "games/asteroids", None,       1500, 300, 100),
    ("graph",       "games/pong",      "graph",     500, 216,  20),
    ("code",        "games/pong",      "code",      500,   0,   0),
    ("menus",       "games/pong",      "markdown",  500, 250,   0),
    ("tilemap",     "games/pong",      "tilemap",   500, 380,  40),
    ("sfxr",        "games/pong",      "sfxr",      500, 536,  20),
    ("particles",   "games/pong",      "particles", 600, 330,  20),
    ("atlas",       "games/pong",      "atlas",     500, 380, 140),
    ("hop",         "games/hop",       None,        400, 216, 150,
     ["--game", "640x480", "--events", " ".join("w230,440@%d" % f for f in range(20, 27))]),   # (zoomed in: the wheel, 7 notches)
]
SIZE = 320

def main():
    editor = os.path.abspath(sys.argv[1])
    out = sys.argv[2] if len(sys.argv) > 2 else "docs/gallery"
    os.makedirs(out, exist_ok=True)
    root = os.path.abspath(".")
    env = dict(os.environ, ROOT=root, SDL_AUDIODRIVER=os.environ.get("SDL_AUDIODRIVER", "dummy"))
    scenes = os.path.join(root, "docs", "gallery", "scenes.lua").replace("\\", "/")
    for n, shot in enumerate(SHOTS, 1):
        what, world, scene, frames, x, y = shot[:6]
        name = "%d" % n                            # (1.png .. 9.png: README.md's grid shows them by number)
        more = shot[6] if len(shot) > 6 else []
        bmp = os.path.join(tempfile.gettempdir(), "gallery_" + what + ".bmp")
        cmd = [editor, world, "--frames", str(frames), "--shot", bmp] + more
        if scene:
            env["SCENE"] = scene
            cmd[2:2] = ["--stopped", "--lite", "dofile('%s')@3" % scenes]
        subprocess.run(cmd, env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=120)
        im = Image.open(bmp).convert("RGB")
        x, y = min(x, im.width - SIZE), min(y, im.height - SIZE)
        im.crop((x, y, x + SIZE, y + SIZE)).save(os.path.join(out, name + ".png"))
        os.remove(bmp)
        print("%s/%s.png: %s" % (out, name, what))

if __name__ == "__main__":
    main()
