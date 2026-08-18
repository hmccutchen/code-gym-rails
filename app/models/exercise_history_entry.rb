# `answered` is nil for an exercise with no response row at all — no recorded
# interaction. That is not the same as "never opened": DashboardController#show
# builds an unsaved DailyResponse, so opening the page and leaving without
# touching anything looks identical here.
ExerciseHistoryEntry = Data.define(:section_keys, :answered)
