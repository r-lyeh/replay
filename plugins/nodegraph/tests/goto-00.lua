-- goto-00: goto and a label.
-- Expect: "goto skip" (no flow out) with a faint wire to "::skip::" ->
--   print("after"). print("skipped") comes right after the goto, so
--   nothing leads into it (it never runs): its flow in stays hollow.
print("before")
goto skip
print("skipped")
::skip::
print("after")
