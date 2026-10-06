class ResponsesController < ApplicationController
  include ProviderCallLimits
  include ProviderFailureRendering

  # Ahead of the other checks, so a request they refuse still counts.
  limit_provider_calls only: [ :explain_differently, :follow_ups, :duck_thread, :pseudocode_critique ]
  before_action :set_response, only: [ :review, :email_review, :explain_differently, :follow_ups, :start_over ]
  before_action :require_reviewed_section!, only: [ :explain_differently, :follow_ups ]

  # Double MAX_FOLLOW_UPS_PER_SECTION (3): a follow-up is one clarifying
  # question about an already-finished review, while a duck thread supports
  # an actual back-and-forth while someone is actively stuck. Lives here
  # rather than on DailyResponse (unlike MAX_FOLLOW_UPS_PER_SECTION) since
  # this feature has no DailyResponse-owned data — the view partial reads it
  # straight off this controller.
  MAX_DUCK_TURNS_PER_SECTION = 6

  # The thread is client-held, so its size is attacker-controlled: the turn cap
  # above counts only "user" roles and so bounds nothing on its own (a crafted
  # request can carry unlimited "assistant" entries). These bound what gets
  # allocated and forwarded to the provider. Generous enough that no honest UI
  # session approaches them — MAX_DUCK_TURNS_PER_SECTION exchanges is at most
  # 12 entries, and the input is a single-line text field. The message limit is
  # in characters because it is quoted back to the user; the thread limit is in
  # bytes because it bounds the payload, and one character is up to four.
  MAX_DUCK_MESSAGE_LENGTH = 2_000
  MAX_DUCK_THREAD_ENTRIES = MAX_DUCK_TURNS_PER_SECTION * 2

  # Derived, not a flat number: a flat 20_000 undercounted its own "generous
  # enough" claim above — MAX_DUCK_TURNS_PER_SECTION honest user turns alone,
  # each at MAX_DUCK_MESSAGE_LENGTH in a worst-case 4-byte-per-character
  # language, is already 6 * 2_000 * 4 = 48_000 bytes, well past a flat
  # 20_000. That falsely rejected a cap-respecting conversation typed in a
  # multi-byte language after only 2-3 exchanges instead of the full 6.
  # Assistant replies aren't character-bounded, only token-bounded by
  # AiService::DUCK_RESPONSE_MAX_TOKENS, so their allowance derives from that
  # cap at a generous bytes-per-token figure rather than being a flat number
  # that a raised cap would silently outgrow — as 1_200 did when the cap moved
  # from 250 to 400. English prose runs about four bytes a token; code and
  # multi-byte text run higher, which the aggregate cap's slack absorbs.
  DUCK_REPLY_BYTES_PER_TOKEN = 4
  DUCK_ASSISTANT_REPLY_BYTE_ALLOWANCE = AiService::DUCK_RESPONSE_MAX_TOKENS * DUCK_REPLY_BYTES_PER_TOKEN
  MAX_DUCK_THREAD_BYTES = MAX_DUCK_TURNS_PER_SECTION *
    (MAX_DUCK_MESSAGE_LENGTH * 4 + DUCK_ASSISTANT_REPLY_BYTE_ALLOWANCE)

  # POST /responses — save answers (auto-save friendly, idempotent)
  def create
    exercise = current_user.daily_exercises.for_date.first
    return head :not_found unless exercise

    @response = persisted_response_for(exercise)
    newly_submitted = false
    saved = @response.with_lock do
      unless @response.submitted?
        assign_draft_response(exercise)
        newly_submitted = @response.submitted?
      end
      @response.save
    end

    enqueue_concept_references(exercise) if saved && newly_submitted
    render_save_result(saved)
  end

  # POST /responses/:id/review — trigger the inline AI review. Synchronous: the
  # request blocks for as long as the provider takes, then lands the user back
  # on the dashboard, whose submitted state renders the finished review in
  # place. Every exit from this action goes to root_path — success, partial,
  # already-reviewed, and each rescue below — so the page never changes under
  # the user based on how the review went.
  #
  # The exits that have a review to show anchor it (see review_anchor); the
  # ones that don't land at the top of that same page.
  def review
    return redirect_to root_path, alert: t("flash.responses.not_submitted") unless @response.submitted?

    missing = @response.section_keys - Array(@response.ai_review&.keys)
    return redirect_to review_anchor, notice: t("flash.responses.already_reviewed") if missing.empty?

    unless claim_review!
      return redirect_to root_path, alert: t("flash.responses.review_already_running")
    end

    # Recompute after reload to close the race: another request may have
    # finished the last missing section between our first check and the claim.
    missing = @response.section_keys - Array(@response.ai_review&.keys)
    if missing.empty?
      release_review_claim!
      return redirect_to review_anchor, notice: t("flash.responses.already_reviewed")
    end

    first_batch = @response.ai_review.blank?
    results = AiService.for(current_user).review_sections(current_user, @response.daily_exercise, @response, sections: missing)
    successes = results.select { |_, r| r[:ok] }
    failures  = results.reject { |_, r| r[:ok] }

    ActiveRecord::Base.transaction do
      # Take the row lock before writing anything. #start_over can destroy this
      # response while the provider call above is running (its stale-claim
      # window is shorter than an untimed request can take), and an UPDATE
      # against a deleted row reports success — without this, ConceptMastery
      # writes would commit for a review no row will ever hold. RegenerateExerciseJob
      # destroys it too, and takes this same lock before deciding to.
      @response.lock!

      if successes.any?
        @response.ai_review = (@response.ai_review || {}).merge(successes.transform_values { |r| r[:review] })
        @response.review_provider = current_user.provider
        ConceptMastery.record_review!(@response, sections: successes.keys, apply_session_countdown: first_batch)
      end
      @response.review_errors = @response.review_errors
                                          .except(*successes.keys)
                                          .merge(failures.transform_values { |r| stored_review_failure(r) })
      @response.save!
    end
    release_review_claim!
    clear_stale_generation_error! if successes.any?
    log_review_diagnostics(@response, successes.keys) if successes.any?

    if failures.empty?
      redirect_to review_anchor, notice: t("flash.responses.review_ready")
    elsif successes.any?
      redirect_to review_anchor, notice: t("flash.responses.review_partial", reviewed: successes.size, total: missing.size,
                                             reason: review_failure_text(failures, :review_partial).brief)
    else
      redirect_to root_path, alert: review_failure_text(failures, :review).full
    end
  rescue ActiveRecord::RecordNotFound
    redirect_to root_path, alert: t("flash.responses.set_cleared_during_review")
  rescue AiService::Error => e
    release_review_claim!
    redirect_to root_path, alert: provider_failure_text(e, :review).full
  end

  # DELETE /responses/:id/start_over — abandon today's saved answers and
  # ratings so the same problem set can be re-attempted from a blank
  # state. Destroys the row outright rather than clearing fields in place —
  # #create's persisted-response lookup handles a missing row cleanly, so
  # the next autosave just creates a fresh one with no special-casing needed
  # anywhere else. Hard-blocked once any section has been reviewed: from that
  # point ConceptMastery.record_review! has already moved real tier/streak
  # state for that concept, and this action has no way to undo that. Also
  # blocked while a review is actively claimed: #review's provider call runs
  # outside a transaction, so destroying the row mid-flight lets its
  # ConceptMastery writes commit against a response that no longer exists.
  def start_over
    return redirect_to root_path, alert: t("flash.responses.start_over_after_review") if @response.reviewed?
    return redirect_to root_path, alert: t("flash.responses.start_over_not_today") unless @response.date == Date.current
    return redirect_to root_path, alert: t("flash.responses.start_over_while_reviewing") if @response.reviewing?

    @response.destroy
    redirect_to root_path, notice: t("flash.responses.answers_cleared")
  end

  # POST /responses/:id/email_review — email the completed review to the user.
  # Both redirects go to root_path: the email button only ever renders on the
  # dashboard's submitted state (_submission.html.erb), not on history, so
  # that's the only page where the user can repeat or confirm the action.
  def email_review
    return redirect_to root_path, alert: t("flash.responses.no_review_to_email") unless @response.fully_reviewed?

    ReviewMailer.send_review(@response).deliver_later
    redirect_to root_path, notice: t("flash.responses.review_emailed", email: current_user.email)
  end

  # POST /responses/:id/explain_differently — one section's feedback, reframed.
  # Synchronous like #review; the caller posts via fetch and appends in place.
  def explain_differently
    existing = Array(@response.review_alternates[@section])
    if existing.size >= DailyResponse::MAX_ALTERNATES_PER_SECTION
      return render_section_error(t("errors.responses.alternates_used", count: DailyResponse::MAX_ALTERNATES_PER_SECTION))
    end

    alternate = AiService.for(current_user).explain_differently(
      current_user, @response.daily_exercise, @response,
      section: @section, prior_alternates: existing
    )

    # The provider call above is slow and deliberately stays outside the lock.
    # The count check above is only advisory — two concurrent requests can both
    # read `existing.size` under the cap and both reach here. with_lock takes a
    # row lock and reloads @response, so this re-check is the real guarantee:
    # if the cap was reached by another request while this one was waiting on
    # the provider, this request backs off here instead of overwriting (and
    # silently dropping) the other request's alternate.
    capped = false
    remaining = nil
    @response.with_lock do
      current = Array(@response.review_alternates[@section])
      if current.size >= DailyResponse::MAX_ALTERNATES_PER_SECTION
        capped = true
      else
        @response.review_alternates = @response.review_alternates.merge(@section => current + [ alternate ])
        @response.save!
        remaining = DailyResponse::MAX_ALTERNATES_PER_SECTION - current.size - 1
      end
    end

    if capped
      render_section_error(t("errors.responses.alternates_used", count: DailyResponse::MAX_ALTERNATES_PER_SECTION))
    else
      render json: { status: "ok", alternate: alternate, remaining: remaining }
    end
  rescue AiService::Error => e
    render_provider_failure(e, :alternate)
  end

  # POST /responses/:id/follow_ups — ask one clarifying question about a section's
  # review. Synchronous: a single short completion, so it needs no job or polling.
  # Both turns are written in one transaction, so a provider failure can never
  # leave an orphaned question with no answer in the thread.
  def follow_ups
    question = params[:question].to_s.strip
    return render_section_error(t("errors.responses.question_blank")) if question.blank?

    asked = @response.review_follow_ups.where(section: @section, role: :user).count
    if asked >= DailyResponse::MAX_FOLLOW_UPS_PER_SECTION
      return render_section_error(t("review.follow_ups_used", count: DailyResponse::MAX_FOLLOW_UPS_PER_SECTION))
    end

    thread = @response.review_follow_ups.for_section(@section).map { |t| { role: t.role, content: t.content } }

    answer = AiService.for(current_user).answer_follow_up(
      current_user, @response.daily_exercise, @response,
      section: @section, question: question, thread: thread
    )

    # The provider call above is slow and deliberately stays outside the lock.
    # The count check above is only advisory — two concurrent requests can both
    # read `asked == 2` and both reach here. with_lock takes a row lock and
    # reloads @response, so this re-check is the real guarantee: if the cap was
    # reached by another request while this one was waiting on the provider,
    # this request backs off here instead of writing a 4th turn.
    capped = false
    remaining = nil
    @response.with_lock do
      current_count = @response.review_follow_ups.where(section: @section, role: :user).count
      if current_count >= DailyResponse::MAX_FOLLOW_UPS_PER_SECTION
        capped = true
      else
        @response.review_follow_ups.create!(section: @section, role: :user, content: question)
        @response.review_follow_ups.create!(section: @section, role: :assistant, content: answer)
        remaining = DailyResponse::MAX_FOLLOW_UPS_PER_SECTION - current_count - 1
      end
    end

    if capped
      render_section_error(t("review.follow_ups_used", count: DailyResponse::MAX_FOLLOW_UPS_PER_SECTION))
    else
      render json: { status: "ok", answer: answer, remaining: remaining }
    end
  rescue AiService::Error => e
    render_provider_failure(e, :follow_up)
  end

  # POST /responses/duck_thread — one turn of the pre-submission Socratic
  # thinking partner. Fully unpersisted: no :id, no DailyResponse row is
  # created or written to. The client sends its own full in-memory thread on
  # every request; the server uses it only to build this one prompt. Reads
  # today's exercise/response only to build context and enforce the
  # unsubmitted gate — never writes to either.
  def duck_thread
    exercise = current_user.daily_exercises.for_date.first
    # A JSON body, not head :not_found — the client's fetch handler always
    # calls res.json() before checking res.ok, so an empty body would raise
    # a confusing "Unexpected end of JSON input" instead of a clean message.
    return render json: { status: "error", error: t("errors.no_exercise_today") }, status: :not_found unless exercise

    section = params[:section].to_s
    # #active_section_keys, not the raw payload keys: a payload can hold a
    # third- or fourth-shaped key the page never rendered, and a section the
    # engineer cannot see is not one they can think out loud about.
    return render_section_error(t("errors.section_not_in_exercise")) unless exercise.active_section_keys.include?(section)

    existing = current_user.daily_responses.find_by(daily_exercise: exercise, date: Date.current)
    return render_section_error(t("errors.responses.duck_after_submit")) if existing&.submitted?

    message = params[:message].to_s.strip
    return render_section_error(t("errors.responses.message_blank")) if message.blank?
    if message.length > MAX_DUCK_MESSAGE_LENGTH
      return render_section_error(t("errors.responses.message_too_long", max: MAX_DUCK_MESSAGE_LENGTH))
    end

    thread = duck_thread_param
    if thread.size > MAX_DUCK_THREAD_ENTRIES ||
       thread.sum { |turn| turn[:content].bytesize } > MAX_DUCK_THREAD_BYTES
      return render_section_error(t("errors.responses.conversation_too_long"))
    end
    unless well_formed_thread?(thread)
      return render_section_error(t("errors.responses.conversation_out_of_step"))
    end
    # Soft, request-level cap: the thread lives only in the browser, so this
    # is not a hardened boundary (a hand-crafted request could understate its
    # own history) — acceptable given each user pays for their own provider
    # calls with their own key. See the design doc's "Cap on exchanges".
    if thread.count { |turn| turn[:role] == "user" } >= MAX_DUCK_TURNS_PER_SECTION
      return render_section_error(t("duck.turns_used", count: MAX_DUCK_TURNS_PER_SECTION))
    end

    answer = AiService.for(current_user).duck_response(
      current_user, exercise, section: section, message: message, thread: thread
    )

    render json: { status: "ok", answer: answer }
  rescue AiService::Error => e
    render_provider_failure(e, :duck)
  end

  # POST /responses/pseudocode_critique — round 1: one text-only critique of the
  # engineer's plan.
  def pseudocode_critique
    return unless (context = load_pseudocode_context)

    row, section, pseudocode = context
    return render_section_error(critique_busy_message(row, section)) unless claim_pseudocode_round!(row, section, "critique", :critiqued?)

    result = AiService.for(current_user).critique_pseudocode(
      current_user, row.daily_exercise, section: section, pseudocode: pseudocode
    )

    write_pseudocode_round!(row, section, "critique",
      "initial_pseudocode" => pseudocode,
      "gaps_found"         => result[:gaps_found],
      "critique"           => result[:gaps],
      "critiqued_at"       => Time.current.iso8601)

    render json: { status: "ok", gaps_found: result[:gaps_found], gaps: result[:gaps] }
  rescue AiService::Error => e
    release_pseudocode_claim!(row, section, "critique")
    render_provider_failure(e, :critique)
  end

  private

  def assign_draft_response(exercise)
    submitted_answers = response_params[:answers]&.slice(*exercise.active_section_keys)
    submitted_answers = DailyResponse.normalize_answers(submitted_answers, exercise) if submitted_answers
    @response.assign_attributes(
      answers: @response.answers.merge(submitted_answers || {}).slice(*exercise.active_section_keys),
      submitted_at: response_params[:submit] == "1" ? Time.current : nil,
      concept_tags: exercise_concept_tags(exercise)
    )
    incoming_ratings = (response_params[:section_ratings] || {})
      .slice(*exercise.active_section_keys)
      .select { |_, value| DailyResponse::SELF_RATINGS.include?(value) }
    @response.section_ratings = @response.section_ratings.merge(incoming_ratings)
    if response_params[:submit] == "1"
      @response.section_ratings = @response.section_ratings.slice(*@response.answered_sections)
    end
  end

  def render_save_result(saved)
    respond_to do |format|
      format.json do
        if saved
          payload = { status: "saved", completeness: @response.completeness, submitted: @response.submitted? }
          payload[:review_url] = review_response_path(@response) if response_params[:submit] == "1"
          render json: payload
        else
          render json: { status: "error", errors: @response.errors.full_messages }, status: :unprocessable_content
        end
      end
      format.html do
        if saved
          redirect_to root_path
        else
          redirect_to root_path, alert: t("flash.responses.save_failed")
        end
      end
    end
  end

  # A non-Hash-like element (e.g. thread: ["oops"] or thread: "not-an-array",
  # which Array() wraps as a one-element array) would otherwise raise
  # TypeError on turn[:role] and surface as a raw 500 instead of the 422
  # every other bad-input path in this action returns.
  # Roles are normalized to lowercase and restricted to user/assistant — the
  # cap check below matches turn[:role] == "user" exactly, so an unnormalized
  # "User"/"USER" would silently dodge the cap. The role reaches the provider
  # now rather than only a rendered transcript, so the second consequence
  # differs per path: Claude takes it as a Messages API role, where anything
  # but user/assistant is a 400 surfacing as a 503, while Gemini's fold would
  # mislabel the speaker for anything it doesn't recognize as exactly
  # "assistant".
  # Blank content is dropped here too: it used to render harmlessly as
  # "Them: " in the flattened prompt, but a real Messages API turn rejects an
  # empty text block outright, which would otherwise reach Anthropic and come
  # back as a 503 instead of the clean 422 every other malformed turn gets.
  def duck_thread_param
    # first(...+1) bounds the mapping itself while still leaving an
    # over-limit thread detectably over limit for the caller's size check.
    Array(params[:thread]).first(MAX_DUCK_THREAD_ENTRIES + 1).filter_map { |turn|
      next unless turn.is_a?(Hash) || turn.respond_to?(:permit)

      role = turn[:role].to_s.downcase
      next unless %w[user assistant].include?(role)

      content = turn[:content].to_s
      next if content.blank?

      { role: role, content: content }
    }
  end

  # A turn array is sent to the provider as real messages now, which is
  # ordered in a way the old flattened transcript was not: turns alternate and
  # the client's history always ends on an assistant reply, since the script
  # pushes both halves of an exchange together. Nothing legitimate produces
  # anything else, so a thread that breaks it is a hand-crafted request, not a
  # user mistake.
  def well_formed_thread?(thread)
    return true if thread.empty?

    thread.last[:role] == "assistant" &&
      thread.each_slice(2).all? { |user_turn, assistant_turn|
        user_turn[:role] == "user" && assistant_turn&.dig(:role) == "assistant"
      }
  end

  # The section is taken from the registry, never from params: these endpoints
  # exist for exactly one kind, so deriving it means no crafted request can aim
  # them at another section and no per-kind comparison has to live in this
  # shared controller. Renders its own error and returns nil, so callers guard
  # on the return value.
  def load_pseudocode_context
    exercise = current_user.daily_exercises.for_date.first
    unless exercise
      render json: { status: "error", error: t("errors.no_exercise_today") }, status: :not_found
      return
    end

    section = ExerciseSection::PseudocodeToCode.key
    return pseudocode_error(t("errors.responses.pseudocode.no_section")) unless exercise.active_section_keys.include?(section)

    pseudocode = validated_pseudocode or return
    row        = open_response_for(exercise) or return

    [ row, section, pseudocode ]
  end

  def validated_pseudocode
    value = params[:pseudocode].to_s.strip
    return pseudocode_error(t("errors.responses.pseudocode.blank")) if value.blank?
    if value.length > ExerciseSection::PseudocodeToCode::MAX_PSEUDOCODE_LENGTH
      return pseudocode_error(t("errors.responses.pseudocode.too_long", max: ExerciseSection::PseudocodeToCode::MAX_PSEUDOCODE_LENGTH))
    end

    value
  end

  # Persisted, because the row lock the rounds claim under needs a real row.
  # Reached only after the request has otherwise validated, so a malformed
  # request never creates one.
  def open_response_for(exercise)
    row = persisted_response_for(exercise)
    return pseudocode_error(t("errors.responses.pseudocode.after_submit")) if row.submitted?

    row
  end

  # Both error classes, because the row is guarded twice and which one fires
  # depends on timing: DailyResponse validates date uniqueness scoped to
  # user_id, so a row already there at validation time raises RecordInvalid,
  # while one inserted after that check raises RecordNotUnique from the index.
  # The dashboard's debounced autosave makes this race the common case, not the
  # exotic one. Re-found by date alone, which is the uniqueness scope — a
  # regenerated day swaps daily_exercise_id.
  def persisted_response_for(exercise)
    current_user.daily_responses.find_or_create_by!(daily_exercise: exercise, date: Date.current)
  rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique
    current_user.daily_responses.find_by!(date: Date.current)
  end

  # Claims the round under the row lock BEFORE the provider call. Claiming
  # afterwards would still bill both of two concurrent requests and only stop
  # the second from storing its result — a cap on a paid call has to bound the
  # spend, not just the write. The claim expires after
  # DailyResponse::REVIEW_CLAIM_STALE_AFTER, the same window #review uses and
  # for the same reason: a crashed or hung request must not lock the round
  # forever. Same shape as #follow_ups' with_lock re-check.
  def claim_pseudocode_round!(row, section, phase, done)
    claimed = false

    row.with_lock do
      next if row.public_send(done, section) || row.pseudocode_claimed?(section, phase)

      row.merge_pseudocode_round!(section, "#{phase}_claimed_at" => Time.current.iso8601)
      claimed = true
    end

    claimed
  end

  # Writing the result also releases the claim, so the two can never disagree.
  def write_pseudocode_round!(row, section, phase, attrs)
    row.with_lock { row.merge_pseudocode_round!(section, attrs.merge("#{phase}_claimed_at" => nil)) }
  end

  # A handled provider failure hands the round back rather than burning it: the
  # engineer paid for nothing, so they should be able to retry immediately
  # instead of waiting out the stale window.
  def release_pseudocode_claim!(row, section, phase)
    return if row.nil?

    row.with_lock { row.merge_pseudocode_round!(section, "#{phase}_claimed_at" => nil) }
  end

  def critique_busy_message(row, section)
    t(row.critiqued?(section) ? "errors.responses.pseudocode.already_checked" : "errors.responses.pseudocode.check_running")
  end

  # render_section_error returns the rendered response, which is truthy; the
  # callers above need a falsy value to mean "already handled".
  def pseudocode_error(message)
    render_section_error(message)
    nil
  end

  # The submitted dashboard renders the whole day's problems and answers above
  # the review, so landing at the top of it leaves the result the user just
  # waited on a page-length scroll away. Same page every other exit uses, one
  # fragment further down; a day with no review renders no #ai-review and the
  # browser stays at the top, which is where those exits want the user anyway.
  def review_anchor
    root_path(anchor: "ai-review")
  end

  def set_response
    @response = current_user.daily_responses.find(params[:id])
  end

  # Shared by every endpoint that writes against an existing review. Ownership is
  # already enforced by set_response's association scope (another user's id raises
  # RecordNotFound → 404, which also avoids leaking whether that id exists); this
  # adds the two guards specific to review-attached writes. Validating the section
  # against the exercise's own problem_set mirrors #create's slice guard — without
  # it a crafted param writes arbitrary keys into the jsonb columns.
  def require_reviewed_section!
    @section = params[:section].to_s
    return render_section_error(t("errors.section_not_in_exercise")) unless @response.daily_exercise.problem_set.key?(@section)
    render_section_error(t("errors.responses.no_review_yet")) unless @response.section_reviewed?(@section)
  end

  def render_section_error(message)
    render json: { status: "error", error: message }, status: :unprocessable_content
  end

  # Atomic claim against a concurrent double-review (e.g. an impatient second
  # click while the first request is still waiting on the provider): a single
  # UPDATE ... WHERE is serialized by Postgres row locking, so only one
  # concurrent caller can affect the row — the loser gets 0 rows and backs off
  # instead of racing into a second provider call and ConceptMastery write.
  def claim_review!
    claimed = DailyResponse.where(id: @response.id)
                           .where("reviewing_since IS NULL OR reviewing_since < ?", DailyResponse::REVIEW_CLAIM_STALE_AFTER.ago)
                           .update_all(reviewing_since: Time.current) == 1
    @response.reload if claimed
    claimed
  end

  def release_review_claim!
    @response.update_column(:reviewing_since, nil)
  end

  # A review closes the day to regeneration (DailyExercisesController#regenerate
  # refuses a reviewed response), and with it every path that clears this
  # message — #generate early-returns once the day has an exercise. So a
  # regeneration failure recorded earlier today would otherwise sit on the
  # dashboard until midnight telling the user to retry something they can no
  # longer do. RegenerateExerciseJob#keep_reviewed_set writes its own message
  # after this point, so the one explanation that is still true survives.
  def clear_stale_generation_error!
    current_user.clear_stale_generation_error!
  end

  # Nearly all difficulty adaptation in this app is advisory; nothing
  # verifies the AI's rating and the engineer's own self-rating ever agree,
  # or that either one shifts with how the prompt says it should. This pairs
  # both per section so a week of entries can be read alongside
  # AiService#log_difficulty_diagnostics (correlated by user_id + date) as
  # "here's what we asked for, here's what we got, here's how it was rated."
  # Safe to remove once that question is settled. See
  # docs/superpowers/plans/2026-08-11-difficulty-diagnostics-logging.md.
  def log_review_diagnostics(response, sections)
    payload = {
      event: "review",
      user_id: response.user_id,
      # daily_exercise.date, not response.date: DailyResponse#date is set
      # independently at save time, so a set generated late at night and
      # first saved after midnight would otherwise log a review event dated
      # a day after the generation event it's meant to correlate with.
      date: response.daily_exercise.date.to_s,
      sections: sections.index_with { |section|
        { ai_rating: response.ai_rating_for(section), self_rating: response.self_rating_for(section) }
      }
    }

    Rails.logger.info("[difficulty_diagnostics] #{payload.to_json}")
    log_pseudocode_review_diagnostics(response, sections)
  end

  # The counterpart to AiService#log_pseudocode_critique, correlated by user id +
  # date the way log_difficulty_diagnostics and this method already correlate.
  #
  # `disagreement` is computed here rather than left to be reconstructed later:
  # the question this instrumentation exists to answer is "how often does a
  # critique that found nothing precede a review that found plenty", and a
  # derived boolean makes that a grep instead of an analysis. Counts and flags
  # only — no pseudocode, no critique text, no "missed" text. The join key
  # locates the row for anyone who needs the content, and application logs are a
  # different store from the database.
  def log_pseudocode_review_diagnostics(response, sections)
    section = ExerciseSection::PseudocodeToCode.key
    return unless sections.include?(section)

    critiqued = response.critiqued?(section)
    gaps      = ExerciseSection::PseudocodeToCode.normalize_critique(response.pseudocode_round(section)["critique"]).size
    missed    = DailyResponse.review_points(graded_missed(response.ai_review&.dig(section))).size

    Rails.logger.info(
      "[pseudocode] user=#{response.user_id} date=#{response.daily_exercise.date} phase=review " \
      "critiqued=#{critiqued} gaps=#{gaps} missed=#{missed} " \
      "disagreement=#{critiqued && gaps.zero? && missed.positive?}"
    )
  end

  # The grader's own missed points: the prose judge may have merged the stored
  # ones, and keeps the originals under graded_prose when it does.
  def graded_missed(review)
    return nil unless review.is_a?(Hash)

    review.dig(ReviewProseVerdict::ORIGINAL_KEY, "missed") || review["missed"]
  end

  # The kind most of the failed sections share, written for this surface. A
  # fan-out usually fails every section the same way; when it does not, the
  # commonest kind is the one worth explaining.
  def review_failure_text(failures, surface)
    kind    = failures.values.map { |f| f[:failure] }.tally.max_by { |_, count| count }.first
    example = failures.values.find { |f| f[:failure] == kind }
    ProviderFailureText.new(kind, provider: example[:provider] || current_user.provider, surface: surface,
                            failed_at: Time.current, zone: current_user.effective_time_zone, retry_after: example[:retry_after])
  end

  # What a failed section keeps: its kind, the quota named and when, never the
  # error's text. The page writes the sentence when it is read.
  def stored_review_failure(result)
    { "kind" => result[:failure], "provider" => result[:provider], "quota_id" => result[:quota_id],
      "retry_after" => result[:retry_after], "at" => Time.current.iso8601 }.compact
  end

  def response_params
    @response_params ||= params.require(:response).permit(
      :submit,
      answers: ExerciseSection.keys,
      section_ratings: ExerciseSection.keys
    )
  end

  # active_section_keys, never ExerciseSection.keys: a payload can hold more
  # third- or fourth-shaped keys than the day resolved, and tagging one the
  # engineer never saw both pollutes the concept history that shapes tomorrow
  # and bills a reference job for a section that was never on screen.
  def exercise_concept_tags(exercise)
    exercise.active_section_keys
      .index_with { |section| exercise.problem_set.dig(section, "concept") }
      .compact
  end

  # Kick off generation for each distinct (concept, language-bucket) lacking a
  # cached reference. The exists? check only avoids obvious no-op jobs; the
  # job re-checks, so a racing duplicate enqueue is harmless.
  def enqueue_concept_references(exercise)
    enqueued = []
    exercise_concept_tags(exercise).each do |section, concept|
      next if concept == "other"
      language = ConceptBucket.for(section, exercise.language)
      pair = [ concept, language ]
      next if enqueued.include?(pair) || ConceptReference.exists?(concept: concept, language: language)
      GenerateConceptReferenceJob.perform_later(concept: concept, language: language, user_id: current_user.id)
      enqueued << pair
    end
  end
end
