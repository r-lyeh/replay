-- float-00: floating code (outside the flow; it doesn't run).
-- Expect: start -> print("runs"); a separate block, not wired, holding
--   print("parked") with a hollow flow in. Wire a flow out into it and the
--   code moves into the flow.
print("runs")
--[==[@float dx=40 dy=120
print("parked")
]==]
