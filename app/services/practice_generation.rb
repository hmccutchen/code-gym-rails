class PracticeGeneration
  include RecordsJudgeSolves

  Outcome = Data.define(:status, :exercise)
  SETTINGS = %w[daily_section_count daily_section_kinds section_kind_preferences_version skill_level section_kind_levels locked_section_kinds section_kind_weights excluded_section_kinds].freeze

  def self.capture(user, date:, replacing: nil)
    User.transaction do
      fresh = User.lock.find(user.id)
      active = PracticePolicyMode.active?(fresh)
      predecessor = PracticeSchedule.context_for(fresh)
      note = PracticeSchedule.context_for(fresh, replacing: replacing)
      context = { active: active, date: date, user_id: user.id, latest_id: fresh.daily_exercises.maximum(:id),
        predecessor: predecessor, note: note, replacing_id: replacing&.id,
        settings: fresh.attributes.slice(*SETTINGS), difficulty: KindDifficulty.for(fresh),
        kind_rungs: fresh.kind_rungs, skill_level: fresh.skill_level,
        evidence: active ? PracticeEvidence.for(fresh, before: date, kinds: DailyKinds.pair(fresh).map(&:key),
          initial_ready: predecessor.fetch("initial_ready", false)) : nil }
      freeze_context(context)
    end
  end

  def self.commit_new(user, context:, judged:, language:, drafted_by:)
    new(user, context, judged, drafted_by).commit_new(language)
  end

  def self.commit_replacement(user, exercise:, claim:, context:, judged:, drafted_by:)
    new(user, context, judged, drafted_by).commit_replacement(exercise, claim)
  end

  def self.freeze_context(value)
    case value
    when Hash then value.each { |key, entry| freeze_context(key); freeze_context(entry) }
    when Array then value.each { |entry| freeze_context(entry) }
    end
    value.freeze
  end
  private_class_method :freeze_context

  def initialize(user, context, judged, provider)
    @user, @context, @judged, @provider = user, context, judged, provider
  end

  def commit_new(language)
    User.transaction do
      fresh = User.lock.find(@user.id)
      active = PracticePolicyMode.active?(fresh)
      existing = fresh.daily_exercises.find_by(date: @context.fetch(:date))
      next outcome(:duplicate, existing) if existing
      next outcome(:superseded) unless current?(fresh, active: active)

      exercise = fresh.daily_exercises.create!(date: @context.fetch(:date), language: language,
        **content, generated_at: Time.current)
      record_judge_solves(exercise, @judged.solves, drafted_by: @provider)
      outcome(:saved, exercise)
    end
  end

  def commit_replacement(exercise, claim)
    User.transaction do
      fresh = User.lock.find(@user.id)
      active = PracticePolicyMode.active?(fresh)
      exercise.with_response_locked do |response|
        next outcome(:superseded, exercise) unless exercise.user_id == fresh.id &&
          exercise.regenerating_since == claim && exercise.id == @context.fetch(:replacing_id) &&
          exercise.date == @context.fetch(:date) && current?(fresh, active: active, replacement: true)
        next outcome(response.replace_blocker, exercise) if response&.replace_blocker

        response&.destroy!
        exercise.update!(**content, plan_notes: replacement_notes(exercise), generated_at: Time.current,
          regenerated_at: Time.current, regenerating_since: nil)
        record_judge_solves(exercise, @judged.solves, drafted_by: @provider)
        outcome(:saved, exercise)
      end
    end
  end

  private

  def outcome(status, exercise = nil) = Outcome.new(status: status, exercise: exercise)

  def current?(fresh, active:, replacement: false)
    return false unless @context.fetch(:user_id) == fresh.id && fresh.attributes.slice(*SETTINGS) == @context.fetch(:settings)
    return false if active != @context.fetch(:active)
    return false unless @judged.schedule_context.equal?(@context) || (!@context.fetch(:active) && @judged.schedule_context.nil?)
    return true if replacement

    fresh.daily_exercises.maximum(:id) == @context.fetch(:latest_id) &&
      PracticeSchedule.context_for(fresh) == @context.fetch(:predecessor)
  end

  def content
    PracticeSchedule::Note.decode(@judged.plan_notes.fetch("practice_schedule")) if @context.fetch(:active)
    { problem_set: @judged.problem_set, dropped_sections: @judged.dropped_sections, plan_notes: @judged.plan_notes }
  end

  def replacement_notes(exercise)
    notes = @judged.plan_notes.deep_dup
    original = exercise.practice_schedule
    return notes.except("practice_schedule") if original.empty?

    changed = notes.fetch("practice_schedule")
    notes["practice_schedule"] = PracticeSchedule::Note.decode(changed.merge(
      original.slice("sequence", "phase", "regular_kinds", "initial_ready", "continuation")))
    notes
  end
end
