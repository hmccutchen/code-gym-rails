# `answered` is nil for an exercise with no response row at all — never opened,
# which is different from opened and left blank.
ExerciseHistoryEntry = Data.define(:section_keys, :answered)
