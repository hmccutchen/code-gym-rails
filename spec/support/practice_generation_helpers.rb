module PracticeGenerationHelpers
  def with_practice_context(result, user:, language:, schedule_context:)
    notes = result.plan_notes.dup
    if schedule_context.fetch(:active)
      key = result.problem_set.keys.sole
      previous = schedule_context.fetch(:note)
      sequence = [ previous.fetch("sequence", 0) + (schedule_context[:replacing_id] ? 0 : 1), 1 ].max
      kinds = previous["version"] == 3 ? previous.dig("continuation", "kind_service").deep_dup : {}
      (kinds[language] ||= {})[key] = sequence unless schedule_context[:replacing_id]
      service = previous["version"] == 3 ? previous.dig("continuation", "service") : {}
      notes["practice_schedule"] = PracticeSchedule::Note.decode(
        "version" => 3, "policy" => 2, "sequence" => sequence,
        "initial_ready" => previous.fetch("initial_ready", false), "regular_kinds" => DailyKinds.pair(user).map(&:key),
        "selected_kinds" => [ key ], "assignments" => {},
        "continuation" => { "kind_service" => kinds, "service" => service })
    end
    result.with(plan_notes: notes, schedule_context: schedule_context)
  end
end
