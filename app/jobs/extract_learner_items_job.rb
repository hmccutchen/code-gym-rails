# Design notes: docs/code-notes/app/jobs/extract_learner_items_job.md
class ExtractLearnerItemsJob < ApplicationJob
  queue_as :provider_calls

  EARLY = "early".freeze
  FALLBACK = "fallback".freeze
  CLAIM_RETRY_WAIT = 5.minutes
  LOGGED_OUTCOMES = { deleted: "account_deleted", replaced: "set_replaced" }.freeze
  SET_LEFT_ALONE = LOGGED_OUTCOMES.keys.freeze

  def self.claim_key(daily_exercise_id) = "learner_items/#{daily_exercise_id}"

  def self.queue_for_submitted(user, exercise)
    return unless LearnerNotes.on_for?(user)

    queue(user, exercise, FALLBACK, wait_until: fallback_at(user))
    queue_early(user, exercise) if ExplainQuestion.options(tags: exercise.section_concepts).empty?
  end

  def self.queue_early(user, exercise) = queue(user, exercise, EARLY)

  # The submit or the explanation is already saved, so a failed enqueue must not fail its request.
  def self.queue(user, exercise, run, **timing)
    set(priority: JobPriority::BACKGROUND, **timing)
      .perform_later(user_id: user.id, daily_exercise_id: exercise.id, daily_response_id: exercise.daily_response&.id, run: run)
  rescue SolidQueue::Job::EnqueueError, ActiveRecord::ConnectionNotEstablished, ActiveRecord::ConnectionFailed => e
    Rails.logger.error("Could not queue learner items (#{run}) for user #{user.id} on #{exercise.date}: #{e.class}")
  end

  def self.discard_waiting(user, daily_exercise_id: nil)
    UnfinishedJobs.discard_job(name, user_id: user.id, daily_exercise_id: daily_exercise_id)
  end

  def self.fallback_at(user, now = Time.current)
    [ now.in_time_zone(user.effective_time_zone).tomorrow.beginning_of_day, now + 1.hour ].max
  end

  def perform(user_id:, daily_exercise_id:, daily_response_id:, run:)
    exercise = DailyExercise.find_by(id: daily_exercise_id, user_id: user_id)
    return unless exercise && User.active.exists?(id: user_id)

    claimed = AdvisoryLock.hold(self.class.claim_key(exercise.id)) { extract(exercise, daily_response_id, run) }
    return if claimed || run != FALLBACK

    self.class.set(priority: JobPriority::BACKGROUND, wait: CLAIM_RETRY_WAIT)
        .perform_later(user_id: user_id, daily_exercise_id: daily_exercise_id, daily_response_id: daily_response_id, run: run)
  end

  private

  # Start over and regeneration replace the response, so a run queued for the old set finds another one and stops.
  def extract(exercise, daily_response_id, run)
    return unless DailyResponse.uncached { DailyResponse.submitted.exists?(id: daily_response_id, daily_exercise_id: exercise.id) }

    user, fresh, note = LearnerNote.uncached do
      [ User.active.find_by(id: exercise.user_id), DailyExercise.find_by(id: exercise.id), LearnerNote.for_set(exercise) ]
    end
    return if user.nil? || fresh.nil?

    ledger = LearnerExtraction.for(fresh)
    return if ledger.closed?

    duck = DuckThread.for(fresh)
    reason = no_call_reason(user, fresh, note, duck)
    return close_without_call(user, fresh, run, reason) if reason
    return close(user, fresh, run) if run == FALLBACK && ledger.attempts >= LearnerExtraction::MAX_ATTEMPTS
    return unless run == FALLBACK || ledger.attempts.zero?
    return unless LearnerExtraction.count_attempt!(fresh, close: run == FALLBACK) == true

    call(user, fresh, daily_response_id, note, duck, run, ledger)
  end

  def no_call_reason(user, exercise, note, duck)
    if !LearnerNotes.on_for?(user) then user.api_key_present? ? "off" : "no_key"
    elsif KeyHold.holds?(user.generation_account_failures) then "key_hold"
    elsif duck_sections(exercise, duck).empty? && !note&.something_to_read? then "nothing_to_read"
    end
  end

  def close_without_call(user, exercise, run, reason)
    close(user, exercise, run)
    Rails.logger.info("[learner_items] user #{user.id} run=#{run} no_call=#{reason}")
  end

  def close(user, exercise, run)
    return unless LearnerExtraction.close!(exercise) == :gone

    Rails.logger.info("[learner_items] user #{user.id} run=#{run} set_gone")
  end

  def call(user, exercise, daily_response_id, note, duck, run, ledger)
    reply = AiService.for(user).extract_learner_items(user, **request_values(user, exercise, note, duck))
    outcome = LearnerItem.merge!(user, reply.items, set_date: exercise.date,
                                                    still_there: still_there(exercise, daily_response_id, note, ledger))
    close(user, exercise, run) unless SET_LEFT_ALONE.include?(outcome)
    log_outcome(user, run, outcome, reply.dropped)
  rescue ProviderError, SetupError => e
    Rails.logger.warn("[learner_items] user #{user.id} run=#{run} failed=#{ProviderFailure.classify(e)}")
  end

  # Runs under the merge's user row lock: nil once the set was replaced or forgotten, else the sources whose text is still the one read.
  def still_there(exercise, daily_response_id, read, ledger)
    lambda do
      LearnerNote.uncached do
        next unless DailyResponse.submitted.exists?(id: daily_response_id, daily_exercise_id: exercise.id)
        next unless forgotten_at(exercise) == ledger.forgotten_at

        now = LearnerNote.for_set(exercise)
        %w[duck answer] + written_sources_kept(read, now)
      end
    end
  end

  def forgotten_at(exercise)
    plan_notes = DailyExercise.where(id: exercise.id).pick(:plan_notes)
    plan_notes && LearnerExtraction::Ledger.from(plan_notes).forgotten_at
  end

  def written_sources_kept(read, now)
    kept = []
    kept << "note" if read&.body.present? && now&.body == read.body
    kept << "explanation" if read&.explanation.present? && now&.explanation == read.explanation
    kept
  end

  def log_outcome(user, run, outcome, dropped)
    return Rails.logger.info("[learner_items] user #{user.id} run=#{run} #{LOGGED_OUTCOMES.fetch(outcome)}") if outcome.is_a?(Symbol)

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
                                      note: note&.holds?(:note) || false, explanation_section: explained_section(note)),
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
    return unless note&.holds?(:note)

    question = NoteQuestion.parse(note.question_key)
    { question: question ? NoteQuestion.text(question) : "(none)", text: note.body }
  end

  def explained_section(note)
    note.explain_section if note&.explanation.to_s.strip.present?
  end

  def explanation_values(note)
    return unless explained_section(note)

    { section: note.explain_section, concept: note.explain_concept, text: note.explanation,
      question: ExplainQuestion.text(note.explain_phrasing, note.explain_concept) }
  end
end
