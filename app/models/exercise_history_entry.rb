# section_keys includes dropped keys so a delivery failure never grows a kind's staleness in SectionRotation.
class ExerciseHistoryEntry < Data.define(:section_keys, :delivered_section_keys, :dropped)
  Completion = Data.define(:answered, :delivered_section_keys, :dropped)
end
