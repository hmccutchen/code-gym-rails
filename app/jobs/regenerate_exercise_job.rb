class RegenerateExerciseJob < ApplicationJob
  queue_as :default

  def perform(user_id:)
    user = User.active.find_by(id: user_id)
    return unless user

    Time.use_zone(user.effective_time_zone) { regenerate(user) }
  end

  private

  def regenerate(user)
    exercise = user.daily_exercises.for_date.first
    return unless exercise&.regenerating_since

    # The claim's timestamp is this worker's token. Presence alone cannot tell
    # this claim from a later one: the paused dashboard can clear it and a
    # second click re-make it while the provider call below is still running.
    claim = exercise.regenerating_since
    problem_set = AiService.for(user).generate_exercise(user, language: exercise.language)

    kept_for = nil
    ActiveRecord::Base.transaction do
      # The reviewed-state guard in DailyExercisesController#regenerate runs a
      # worker hop and a 10-30s provider call earlier than this destroy, so a
      # review started in another tab can land inside that window. Both halves of
      # the re-check are load-bearing, and they cover different windows: #review
      # claims the row with a bare UPDATE and takes the row lock only inside the
      # transaction that writes its result, so during its provider call nothing
      # is locked and this SELECT would win uncontended — #reviewing? is what
      # sees that in-flight review, and the lock is what serializes this destroy
      # against the write that finishes one. Dropping either lets a review the
      # user has already paid for be destroyed.
      #
      # The whole regeneration is abandoned rather than the destroy alone —
      # replacing the problem_set under a review would leave that review
      # describing code the day no longer shows.
      #
      # One locked SELECT rather than a load followed by #lock!: a concurrent
      # #start_over can delete the row between those two statements, and #lock!
      # raises RecordNotFound on a row that has gone — which no rescue below
      # catches, so the claim would be stranded until it goes stale. A row
      # already gone is simply nil here, which is the no-response case.
      # The claim is this worker's only title to the row, and it can be
      # released underneath the provider call: User#carry_forward clears it
      # when a held set moves to today, from a resume or from a paused
      # dashboard load after midnight. Re-read under the row lock; a cleared
      # claim means the set is now the one the user is looking at, so the
      # generated set is discarded rather than written over it.
      exercise.lock!
      kept_for = :released unless exercise.regenerating_since == claim
      existing = DailyResponse.lock.find_by(daily_exercise_id: exercise.id)
      kept_for = :reviewed if kept_for.nil? && existing&.reviewed?
      kept_for = :reviewing if kept_for.nil? && existing&.reviewing?
      raise ActiveRecord::Rollback if kept_for

      existing&.destroy
      exercise.update!(
        problem_set:        problem_set,
        generated_at:       Time.current,
        regenerated_at:     Time.current,
        regenerating_since: nil
      )
    end

    return keep_moved_set(user) if kept_for == :released
    return keep_reviewed_set(user, exercise, kept_for, claim) if kept_for

    user.update!(last_generation_error_date: nil, last_generation_error: nil) if user.last_generation_error_date.present?
    Rails.logger.info("Regenerated exercise for #{user.email} on #{Date.current}")
  rescue AiService::AuthenticationError => e
    release(user, exercise, claim, "Your API key was rejected — check it in Settings.", e)
  rescue AiService::RateLimitError => e
    release(user, exercise, claim, "The AI provider is rate-limiting requests — try again shortly.", e)
  rescue AiService::TimeoutError => e
    release(user, exercise, claim, "Generation took longer than the provider's budget — try again.", e)
  rescue AiService::Error => e
    release(user, exercise, claim, e.message, e)
  rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotSaved => e
    release(user, exercise, claim, "Generation returned an unusable set — try again.", e)
  end

  # Rendered after the dashboard's "Couldn't generate a new set: " prefix. A
  # finished review and a running one are told apart because a running one can
  # still fail, and a message asserting a review that never landed would be a
  # false explanation for why the set is unchanged.
  KEPT_SET_MESSAGES = {
    reviewed:  "your review landed first, and replacing a reviewed set would discard it — today's reviewed set was kept.",
    reviewing: "a review was running for today's set, so it was kept rather than replaced mid-review."
  }.freeze

  # No error banner: the set on the dashboard is intact and the move that
  # released the claim cleared the day's error on purpose. Nothing to release
  # either, since whoever moved the set already did.
  def keep_moved_set(user)
    Rails.logger.info("Kept the carried-forward set for #{user.email} on #{Date.current}; discarded the regenerated one")
  end

  # Same shape as a failed attempt — the claim is released and regenerated_at
  # stays nil, so the day's one regeneration is still available once the review
  # is no longer the reason to refuse. The generated set is discarded: it was
  # built for a day whose sections must not change.
  def keep_reviewed_set(user, exercise, kept_for, claim)
    Rails.logger.info("Kept today's set (#{kept_for}) for #{user.email} on #{Date.current}; discarded the regenerated one")
    release_own_claim(exercise, claim)
    user.update!(last_generation_error_date: Date.current, last_generation_error: KEPT_SET_MESSAGES.fetch(kept_for))
  end

  # Releases only the claim this worker holds: a where-guarded UPDATE, so a
  # newer claim made after ours was cleared is left for its own worker.
  def release_own_claim(exercise, claim)
    DailyExercise.where(id: exercise.id, regenerating_since: claim).update_all(regenerating_since: nil)
  end

  # regenerated_at is deliberately left untouched: a failed attempt must not
  # consume the user's one regeneration for the day.
  def release(user, exercise, claim, message, error)
    Rails.logger.error("Failed to regenerate exercise for #{user.email}: #{error.message}")
    release_own_claim(exercise, claim) if exercise
    user.update!(last_generation_error_date: Date.current, last_generation_error: message)
  end
end
