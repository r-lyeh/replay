# lite
![screenshot](https://user-images.githubusercontent.com/3920290/81471642-6c165880-91ea-11ea-8cd1-fae7ae8f0bc4.png)

This is a tailored fork of the greatest lightweight text editor ever written in Lua.

This fork is very specific and you probably meant to visit the original repo instead:

https://github.com/rxi/lite/

## Main differences against original repo
If you are still interested in this, here you have some major diffs:
1. Amalgamated as single-file source.
1. Platform agnostic now (no more specific SDL calls; tested with GLFW backend).
1. Specific `lt_` platform bits have been moved out to an external file (lite_sys.h)
1. Lua, stb-truetype and lite_sys headers *must be included* beforehand.
1. Embeddable: reverted loop handler from framework to library mode. see: lt_init()/lt_tick()
1. Data folders reorganized as data/themes, data/languages/ and data/plugins/.
1. DATADIR path can be specified now (EXEDIR/data/ no longer needed)
1. Packaged with a bunch of handy plugins from https://github.com/rxi/lite-plugins
1. Packaged with all color themes from https://github.com/rxi/lite-colors
1. Merged multi-cursors in from https://github.com/adamharrison/lite-xl
1. Merged a few pending PRs and pending fixes from original repo.
1. Fixed for Lua >= 5.2

## License
This project is free software; you can redistribute it and/or modify it under
the terms of the MIT license.

See [LICENSE](https://github.com/r-lyeh/lite/blob/master/lite.h#L1-L19) for details.
