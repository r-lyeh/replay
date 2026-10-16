-- the game's network settings (online and the Players button); a system may
-- change them while it plays: w:node("/config").c.net.rate = 10
return {
  rate   = 20,    -- the host's states a second (a node may ask for its own: replicate.rate)
  bundle = true,  -- one datagram a peer an update (false: one a message)
  keys   = 60,    -- a player's commands (its keys) a second, at most the tick rate
  hz     = 60,    -- fixed ticks a second, read when the session starts
  -- budget = 1200, -- bytes of states to a player a send: the higher priority first
}
