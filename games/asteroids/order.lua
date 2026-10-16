-- order: what's drawn first. /entities (the rocks, the shots, the sparks)
-- under /objects (the ships, then the HUD on top). The starfield is the
-- root's own image (image.lua): under everything.
return { "/entities", "/objects", "/objects/ship*", "/objects/hud" }
