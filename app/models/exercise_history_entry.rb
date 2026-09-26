# `answered` is nil for an exercise with no response row at all — no recorded
# interaction. That is not the same as "never opened": DashboardController#show
# builds an unsaved DailyResponse, so opening the page and leaving without
# touching anything looks identical here.
#
# `delivered_section_keys` is DailyExercise#active_section_keys, the sections
# the engineer was shown. `section_keys` adds the dropped keys to it, so
# SectionRotation reads a dropped kind as scheduled — a delivery failure must
# not grow a kind's staleness. `dropped` counts those keys; how much of it
# SectionCount credits is decided there, in credited_sections.
ExerciseHistoryEntry = Data.define(:section_keys, :delivered_section_keys, :answered, :dropped)
