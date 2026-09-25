# `answered` is nil for an exercise with no response row at all — no recorded
# interaction. That is not the same as "never opened": DashboardController#show
# builds an unsaved DailyResponse, so opening the page and leaving without
# touching anything looks identical here.
#
# `dropped` counts sections the judge removed that day. They sit inside
# section_keys so rotation reads them as scheduled — a delivery failure must
# not grow a kind's staleness — and SectionCount adds them back to answered
# so a drop neither shortens tomorrow nor reads as a skip.
ExerciseHistoryEntry = Data.define(:section_keys, :answered, :dropped)
