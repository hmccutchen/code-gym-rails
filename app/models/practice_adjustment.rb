class PracticeAdjustment
  def self.resolve(assignments:, difficulty:, rungs:, reduced:)
    rungs.to_h do |key, _rung|
      assigned = assignments.fetch(key, {})
      mode = assigned[:mode]
      mode ||= reduced.fetch(key, []).include?(assigned[:concept]) ? "simplified" : "normal"
      raise ArgumentError, "Invalid practice adjustment" unless PracticeSchedule::Note::ADJUSTMENTS.include?(mode)

      suppressed = difficulty.locked?(ExerciseSection.for(key)) && mode != "normal"
      resolved = suppressed ? "normal" : mode
      [ key, assigned.slice(:concept, :bucket, :source_response_id, :gap).merge(
        mode: resolved, eased: resolved == "simplified", lock_suppressed: suppressed) ]
    end
  end
end
