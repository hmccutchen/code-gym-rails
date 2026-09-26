# `answered` is nil for an exercise with no response row at all — no recorded
# interaction. That is not the same as "never opened": DashboardController#show
# builds an unsaved DailyResponse, so opening the page and leaving without
# touching anything looks identical here.
#
# `delivered_section_keys` is the delivered set, derived from
# DailyExercise#active_section_keys. SectionRotation still needs the scheduled
# set, so `section_keys` keeps the dropped keys alongside the delivered ones.
#
# `dropped` counts sections the judge removed that day. They sit inside
# section_keys so rotation reads them as scheduled — a delivery failure must
# not grow a kind's staleness — and SectionCount credits them only up to what
# the engineer actually saw, so a drop neither shortens tomorrow nor invents
# completion.
ExerciseHistoryEntry = Data.define(:section_keys, :delivered_section_keys, :answered, :dropped)
