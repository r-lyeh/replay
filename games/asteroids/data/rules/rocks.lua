-- rocks: how many a round starts with, seconds between new ones (each one
-- comes a little sooner: x ramp, down to every_min), at most max at once,
-- their speed range and spin. A size splits into two of the next.
return {
  first = 3, every = 3.5, ramp = 0.95, every_min = 0.9, max = 26,
  speed_min = 30, speed_max = 85, spin = 1.2,
  sizes = {
    big = { r = 40, w = 96, image = "/assets/rocks/big.png", next = "medium" },
    medium = { r = 25, w = 60, image = "/assets/rocks/medium.png", next = "small" },
    small = { r = 15, w = 36, image = "/assets/rocks/small.png" },
  },
}
