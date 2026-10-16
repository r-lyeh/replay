-- class-00: ---@class drives a table node.
-- Expect: a table node titled "Paddle": speed is a slider (0..10), mode a
--   drop-down (slow|fast), tint a colour swatch; "+ alive: boolean" (a
--   missing field: one click adds it). RMB > Types lists Paddle.
---@alias Mode "slow"|"fast"
---@class Paddle
---@field speed number @range 0 10
---@field mode Mode
---@field tint Color
---@field alive boolean

---@type Paddle
local p = { speed = 3, mode = "slow", tint = { 200, 80, 80 } }
return p
