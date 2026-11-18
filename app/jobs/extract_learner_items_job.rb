class ExtractLearnerItemsJob < ApplicationJob
  queue_as :provider_calls

  EARLY = "early".freeze
  FALLBACK = "fallback".freeze
  CLAIM_RETRY_WAIT = 5.minutes

  def self.claim_key(daily_exercise_id) = "learner_items/#{daily_exercise_id}"

  def self.queue_for_submitted(user, exercise)
    return unless LearnerNotes.enabled? && user.learner_notes_enabled?

    queue(user, exercise, FALLBACK, wait_until: fallback_at(user))
    queue_early(user, exercise) if ExplainQuestion.options(tags: exercise.section_concepts).empty?
  end

  def self.queue_early(user, exercise) = queue(user, exercise, EARLY)

  # The submit or the explanation is already saved, so a failed enqueue must not fail its request.
  def self.queue(user, exercise, run, **timing)
    set(priority: JobPriority::BACKGROUND, **timing).perform_later(user_id: user.id, daily_exercise_id: exercise.id, run: run)
  rescue SolidQueue::Job::EnqueueError, ActiveRecord::ConnectionNotEstablished, ActiveRecord::ConnectionFailed => e
    Rails.logger.error("Could not queue learner items (#{run}) for user #{user.id} on #{exercise.date}: #{e.class}")
  end

  def self.fallback_at(user, now = Time.current)
    [ now.in_time_zone(user.effective_time_zone).tomorrow.beginning_of_day, now + 1.hour ].max
  end

  def perform(user_id:, daily_exercise_id:, run:)
    exercise = DailyExercise.find_by(id: daily_exercise_id, user_id: user_id)
    return unless exercise && User.active.exists?(id: user_id)

    claimed = AdvisoryLock.hold(self.class.claim_key(exercise.id)) { extract(exercise, run) }
    return if claimed || run != FALLBACK

    self.class.set(priority: JobPriority::BACKGROUND, wait: CLAIM_RETRY_WAIT)
        .perform_later(user_id: user_id, daily_exercise_id: daily_exercise_id, run: run)
  end

  private

  def extract(exercise, run)
    user, note = LearnerNote.uncached { [ User.active.find_by(id: exercise.user_id), LearnerNote.extraction_row(exercise) ] }
    return if user.nil? || note.extracted?

    duck = DuckThread.for(exercise)
    reason = no_call_reason(user, exercise, note, duck)
    return close_without_call(user, note, run, reason) if reason
    return note.close_extraction! if run == FALLBACK && note.extract_attempts >= LearnerNote::MAX_EXTRACT_ATTEMPTS
    return unless (run == FALLBACK || note.extract_attempts.zero?) && note.count_extract_attempt!(close: run == FALLBACK)

    call(user, exercise, note, duck, run)
  end

  def no_call_reason(user, exercise, note, duck)
    if !(LearnerNotes.enabled? && user.learner_notes_enabled?) then "off"
    elsif user.api_key.blank? then "no_key"
    elsif KeyHold.holds?(user.generation_account_failures) then "key_hold"
    elsif duck_sections(exercise, duck).empty? && !note.something_to_read? then "nothing_to_read"
    end
  end

  def close_without_call(user, note, run, reason)
    note.close_extraction!
    Rails.logger.info("[learner_items] user #{user.id} run=#{run} no_call=#{reason}")
  end

  def call(user, exercise, note, duck, run)
    reply = AiService.for(user).extract_learner_items(user, **request_values(user, exercise, note, duck))
    outcome = LearnerItem.merge!(user, reply.items, set_date: exercise.date)
    note.close_extraction!
    log_outcome(user, run, outcome, reply.dropped)
  rescue ProviderError, SetupError => e
    Rails.logger.warn("[learner_items] user #{user.id} run=#{run} failed=#{ProviderFailure.classify(e)}")
  end

  def log_outcome(user, run, outcome, dropped)
    return Rails.logger.info("[learner_items] user #{user.id} run=#{run} account_deleted") if outcome == :deleted

    counts = dropped.merge(outcome.dropped) { |_reason, parsed, merged| parsed + merged }
    Rails.logger.info("[learner_items] user #{user.id} run=#{run} written=#{outcome.written} absorbed=#{outcome.absorbed} " \
                      "dropped=#{counts.map { |reason, count| "#{reason}:#{count}" }.join(",")}")
  end

  def request_values(user, exercise, note, duck)
    response = exercise.daily_response
    response = nil unless response&.submitted?
    sections = exercise.active_section_keys
    { buckets: ConceptBucket.slice_for(user.language) | [ exercise.language ],
      day: LearnerItemsReply::Day.new(date: exercise.date, duck_sections: duck_sections(exercise, duck),
                                      answered_sections: sections.select { |key| response&.answered?(key) },
                                      note: note.body.to_s.strip.present?, explanation_section: explained_section(note)),
      sections: sections.map { |key| section_values(exercise, response, duck, key) },
      note: note_values(note), explanation: explanation_values(note),
      open_items: LearnerItem.open_for_prompt(user), earlier_items: LearnerItem.earlier_labels(user, set_date: exercise.date) }
  end

  def duck_sections(exercise, duck)
    exercise.active_section_keys.select do |key|
      duck.turns_for(key).any? { |turn| turn[:role].to_s == "user" && turn[:content].to_s.strip.present? }
    end
  end

  def section_values(exercise, response, duck, key)
    { key: key, data: exercise.problem_set[key], answer: response&.answer_for(key).to_s, turns: duck.turns_for(key) }
  end

  def note_values(note)
    return unless note.body.to_s.strip.present?

    question = NoteQuestion.parse(note.question_key)
    { question: question ? NoteQuestion.text(question) : "(none)", text: note.body }
  end

  def explained_section(note)
    note.explain_section if note.explanation.to_s.strip.present?
  end

  def explanation_values(note)
    return unless explained_section(note)

    { section: note.explain_section, concept: note.explain_concept, text: note.explanation,
      question: ExplainQuestion.text(note.explain_phrasing, note.explain_concept) }
  end
end
