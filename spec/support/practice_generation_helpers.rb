module PracticeGenerationHelpers
  def with_practice_context(result, user:, language:, schedule_context:)
    notes = result.plan_notes.dup
    if schedule_context.fetch(:active)
      key = result.problem_set.keys.sole
      previous = schedule_context.fetch(:note)
      sequence = [ previous.fetch("sequence", 0) + (schedule_context[:replacing_id] ? 0 : 1), 1 ].max
      kinds = previous.dig("continuation", "kind_service").to_h.merge(key => sequence)
      notes["practice_schedule"] = PracticeSchedule::Note.decode(
        "version" => 2, "policy" => 2, "sequence" => sequence,
        "initial_ready" => previous.fetch("initial_ready", false), "regular_kinds" => DailyKinds.pair(user).map(&:key),
        "selected_kinds" => [ key ], "assignments" => {},
        "continuation" => { "kind_service" => kinds, "service" => previous.dig("continuation", "service") || {} })
    end
    result.with(plan_notes: notes, schedule_context: schedule_context)
  end
end
