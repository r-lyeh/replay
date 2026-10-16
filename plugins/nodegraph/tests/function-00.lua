-- function-00: functions, annotations, lambdas.
-- Expect: a frame "local function area" (outputs w, h: number from
--   ---@param) -> return (pin named "result" from ---@return); a call
--   node "area" whose output is named result; a table holding a lambda
--   (on_hit): its frame hangs under the table.
---@param w number
---@param h number
---@return number result
local function area(w, h)
  return w * h
end
local handlers = {
  on_hit = function(who) print(who) end,
}
print(area(3, 4))
return handlers
