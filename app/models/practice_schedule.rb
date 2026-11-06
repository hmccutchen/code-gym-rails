class PracticeSchedule
  Selection = Data.define(:kinds, :rotation, :assignments, :notes, :continuation)

  def self.plan(context:, count:, setting:, daily:, preferences:, evidence:, hosts:, rotation_history:, due:, drills:, replacing: false,
                regular: daily.first(DailyKinds::COUNT))
    turn_evidence = replacing && context.blank? ? evidence.merge(initial_reviewed_sets: 0) : evidence
    turn = Turns.plan(context: context, count: count, setting: setting, daily: daily, regular: regular, preferences: preferences,
      evidence: turn_evidence, hosts: hosts, rotation_history: rotation_history, due: due, drills: drills)
    turn = replacement_turn(turn, context, count, setting, daily, regular, preferences, rotation_history) if replacing && context.present?
    assignments, service = Assignments.plan(kinds: turn.kinds, hosts: hosts, pending: evidence.fetch(:pending),
      reinforcement: evidence.fetch(:reinforcement, []), due: due, drills: drills,
      service: turn.note.fetch("continuation").fetch("service"), sequence: turn.note.fetch("sequence"))
    assignments = SharedConcept.on_spare_hosts(assignments, evidence.fetch(:reinforcement, []), hosts, kinds: turn.kinds, daily: daily)
    note = turn.note.deep_dup
    note["assignments"] = assignments.transform_values do |entry|
      { "concept" => entry.fetch(:concept), "bucket" => entry.fetch(:bucket),
        "reason" => entry.fetch(:reason), "adjustment" => entry.fetch(:mode, "normal") }
    end
    note["continuation"]["service"] = service unless replacing
    Selection.new(kinds: turn.kinds, rotation: turn.rotation, assignments: assignments,
      notes: Note.decode(note), continuation: note.fetch("continuation"))
  end

  def self.replacement_turn(turn, original, count, setting, daily, regular, preferences, history)
    previous = Note.decode(original)
    kinds = previous.fetch("selected_kinds").map { |key| ExerciseSection.for(key) }
    valid = previous.fetch("regular_kinds") == regular.map(&:key) && kinds.size == count &&
      (setting.nil? || (daily - kinds).empty?) &&
      (kinds - daily).all? { |kind| ExerciseSection.pickable(daily: daily).include?(kind) && !preferences.excluded?(kind) }
    unless valid
      current_rotation = SectionRotation.for(history, count: count, daily: daily, preferences: preferences)
      kinds = ExerciseSection.for_plan(daily: daily, rotation: current_rotation)
    end
    rotation = ExerciseSection.optional_slots(daily: daily).transform_values do |options|
      (options & kinds).first&.key&.to_sym
    end
    note = turn.note.merge(previous.slice("sequence", "phase", "regular_kinds", "initial_ready", "continuation"),
      "selected_kinds" => kinds.map(&:key)).except("omitted_kind")
    note["omitted_kind"] = previous["omitted_kind"] if valid && previous["omitted_kind"]
    Turns::Result.new(kinds: kinds, rotation: rotation, note: note)
  end
  private_class_method :replacement_turn

  def self.context_for(user, replacing: nil)
    return replacing.practice_schedule if replacing

    row = user.daily_exercises.where("plan_notes ? 'practice_schedule'").order(id: :desc).first
    row&.practice_schedule || {}
  end
end
