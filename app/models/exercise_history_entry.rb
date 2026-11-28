# section_keys includes dropped keys so a delivery failure never grows a kind's staleness in SectionRotation.
ExerciseHistoryEntry = Data.define(:section_keys, :delivered_section_keys, :dropped, :planning_host_keys, :schedule_sequence) do
  def initialize(planning_host_keys: nil, schedule_sequence: nil, **attributes) = super
end
