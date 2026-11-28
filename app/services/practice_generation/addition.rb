class PracticeGeneration::Addition < PracticeGeneration
  def self.capture(user, addition:, claim:)
    ExerciseAdditionRequest.with_locked(addition.daily_exercise) do |fresh, exercise, response|
      operation = exercise.exercise_additions.lock.find_by(id: addition.id)
      next unless fresh.id == user.id && eligible?(fresh, exercise, response, operation, claim)

      context = PracticeGeneration.capture(fresh, date: exercise.date).merge(
        requested_kind: operation.kind, addition_id: operation.id, addition_claim: claim,
        exercise_id: exercise.id, draft_scope: exercise.draft_scope, manifest: exercise.active_section_keys,
        key_identity: key_identity(fresh), existing_bug_hunt: exercise.plan_notes["bug_hunt"],
        existing_concepts: exercise.section_concepts.filter_map(&:last))
      freeze_context(context)
    end
  end

  def self.eligible?(user, exercise, response, addition, claim)
    addition && addition.status == "running" && addition.claimed_at == claim && !addition.expired? &&
      addition.date == exercise.date && addition.draft_scope == exercise.draft_scope &&
      ExerciseAdditionRequest.current?(user, exercise) && !response&.submitted? && !exercise.regenerating? &&
      user.provider_ready? && ExerciseAddition.available_kinds(user, exercise).any? { |kind| kind.key == addition.kind }
  end

  def self.key_identity(user) = Digest::SHA256.hexdigest(user.key_in_use.to_json)

  def commit(addition, claim)
    ExerciseAdditionRequest.with_locked(addition.daily_exercise) do |fresh, exercise, response|
      operation = exercise.exercise_additions.lock.find_by(id: addition.id)
      next outcome(:superseded, exercise) unless append_current?(fresh, exercise, response, operation, claim)

      key = operation.kind
      note = @judged.plan_notes["practice_schedule"]
      raise ArgumentError, "Generated sections do not match the requested exercise" unless @judged.problem_set.keys == [ key ] && @judged.dropped_sections.empty?

      notes = appended_notes(exercise, key, note)
      exercise.update!(problem_set: exercise.problem_set.merge(@judged.problem_set),
        section_order: exercise.active_section_keys + [ key ], plan_notes: notes)
      operation.update!(status: "succeeded", claimed_at: nil)
      record_judge_solves(exercise)
      outcome(:saved, exercise)
    end || outcome(:superseded)
  end

  private

  def append_current?(fresh, exercise, response, operation, claim)
    self.class.eligible?(fresh, exercise, response, operation, claim) &&
      fresh.id == @user.id && exercise.id == @context.fetch(:exercise_id) &&
      operation.id == @context.fetch(:addition_id) && operation.kind == @context.fetch(:requested_kind) &&
      claim == @context.fetch(:addition_claim) && exercise.draft_scope == @context.fetch(:draft_scope) &&
      exercise.active_section_keys == @context.fetch(:manifest) &&
      self.class.key_identity(fresh) == @context.fetch(:key_identity) &&
      current?(fresh, active: PracticePolicyMode.active?(fresh))
  end

  def appended_notes(exercise, key, generated)
    notes = exercise.plan_notes.deep_dup
    notes["kind_rungs"] = notes.fetch("kind_rungs", {}).merge(@judged.plan_notes.fetch("kind_rungs", {}).slice(key))
    notes["bug_hunt"] = @judged.plan_notes["bug_hunt"] if @judged.plan_notes["bug_hunt"]
    notes["additions"] ||= {}
    notes["additions"][key] = generated ? generated.slice("sequence").merge("assignment" => generated.fetch("assignments")[key]).compact : {}
    return notes unless generated

    generated = PracticeSchedule::Note.decode(generated)
    canonical = @user.daily_exercises.where("plan_notes ? 'practice_schedule'").order(id: :desc).first
    original = canonical&.practice_schedule || {}
    combined = original.empty? ? generated.merge("selected_kinds" => exercise.active_section_keys, "assignments" => {}) : original.deep_dup
    # Translate legacy continuation through the current planner, preserving its original envelope.
    combined["version"] = 3
    combined["policy"] = 2
    combined.delete("phase")
    combined.delete("omitted_kind")
    combined["continuation"] = merged_continuation(original, generated, key, exercise.language)
    combined = PracticeSchedule::Note.decode(combined)
    if canonical && canonical.id != exercise.id
      canonical.update!(plan_notes: canonical.plan_notes.merge("practice_schedule" => combined))
    else
      notes["practice_schedule"] = combined
    end
    notes
  end
  def merged_continuation(original, generated, key, language)
    return generated.fetch("continuation") unless original["version"] == 3

    continuation = original.fetch("continuation").deep_dup
    %w[kind_service service].each do |field|
      incoming = generated.dig("continuation", field, language) || {}
      next unless incoming.key?(key)

      continuation[field][language] ||= {}
      continuation[field][language][key] = incoming.fetch(key)
    end
    continuation
  end
end
