# section_keys includes dropped keys so a delivery failure never grows a kind's staleness in SectionRotation.
ExerciseHistoryEntry = Data.define(:section_keys, :delivered_section_keys, :answered, :dropped)
