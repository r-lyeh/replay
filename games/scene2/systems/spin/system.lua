-- spin: nodes with xform + spin rotate (spin = radians per second)
return { requires = { "xform", "spin" }, run = function(w, n, dt)
  n.c.xform.r = (n.c.xform.r or 0) + n.c.spin * dt
end }
