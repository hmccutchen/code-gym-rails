class ResponsesController < ApplicationController
  before_action :set_response, only: [ :review, :email_review, :self_explanation, :explain_differently, :follow_ups, :start_over ]
  before_action :require_reviewed_section!, only: [ :self_explanation, :explain_differently, :follow_ups ]

  # Double MAX_FOLLOW_UPS_PER_SECTION (3): a follow-up is one clarifying
  # question about an already-finished review, while a duck thread supports
  # an actual back-and-forth while someone is actively stuck. Lives here
  # rather than on DailyResponse (unlike MAX_FOLLOW_UPS_PER_SECTION) since
  # this feature has no DailyResponse-owned data — the view partial reads it
  # straight off this controller.
  MAX_DUCK_TURNS_PER_SECTION = 6

  # A pseudocode plan for a 15-25 line problem. Generous enough not to clip a
  # verbose planner, bounded because it is user text going into a prompt.
  MAX_PSEUDOCODE_LENGTH = 6_000

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
  # Assistant replies aren't character-bounded (only by
  # AiService::DUCK_RESPONSE_MAX_TOKENS tokens), so they get a generous
  # per-turn byte allowance instead of a precise token->byte conversion.
  DUCK_ASSISTANT_REPLY_BYTE_ALLOWANCE = 1_200
  MAX_DUCK_THREAD_BYTES = MAX_DUCK_TURNS_PER_SECTION *
    (MAX_DUCK_MESSAGE_LENGTH * 4 + DUCK_ASSISTANT_REPLY_BYTE_ALLOWANCE)

  # POST /responses — save answers (auto-save friendly, idempotent)
  def create
    exercise = current_user.daily_exercises.for_date.first
    return head :not_found unless exercise

    @response = current_user.daily_responses.find_or_initialize_by(
      daily_exercise: exercise,
      date: Date.current
    )

    # Only persist answers for sections this exercise actually presents. Strong
    # params permit every third-slot key (`challenge`, `architecture`,
    # `security_review`, `parsons_problem`) and every fourth-slot key
    # (`plan_review`, `ambiguity_hunt`), so without this a crafted request could
    # store keys this exercise never rendered and push
    # DailyResponse#answered_sections / #completeness past this exercise's actual
    # section count / 100%. Sliced against #active_section_keys rather than the
    # raw payload keys, since those are the same sections #completeness counts
    # against — a payload holding two third-shaped keys renders only one.
    submitted_answers = response_params[:answers]&.slice(*exercise.active_section_keys)
    submitted_answers = DailyResponse.normalize_answers(submitted_answers, exercise) if submitted_answers

    @response.assign_attributes(
      answers:      submitted_answers.presence || @response.answers,
      submitted_at: response_params[:submit] == "1" ? Time.current : @response.submitted_at,
      concept_tags: exercise_concept_tags(exercise)
    )

    incoming_ratings = (response_params[:section_ratings] || {})
                         .slice(*exercise.active_section_keys)
                         .select { |_, value| DailyResponse::SELF_RATINGS.include?(value) }
    @response.section_ratings = @response.section_ratings.merge(incoming_ratings)
    @response.feedback_text = response_params[:feedback_text] if response_params.key?(:feedback_text)

    saved = @response.save

    enqueue_concept_references(exercise) if saved && response_params[:submit] == "1"

    respond_to do |format|
      format.json do
        if saved
          payload = { status: "saved", completeness: @response.completeness }
          payload[:redirect] = root_path if response_params[:submit] == "1"
          render json: payload
        else
          render json: { status: "error", errors: @response.errors.full_messages }, status: :unprocessable_content
        end
      end
      format.html do
        if saved
          redirect_to root_path
        else
          redirect_to root_path, alert: "Couldn't save your answers."
        end
      end
    end
  end

  # POST /responses/:id/review — trigger the inline AI review. Synchronous: the
  # request blocks for as long as the provider takes, then lands the user on the
  # history page anchored to the day they just had reviewed.
  def review
    return redirect_to root_path, alert: "Submit your answers first." unless @response.submitted?

    missing = @response.section_keys - Array(@response.ai_review&.keys)
    return redirect_to history_anchor, notice: "Already reviewed." if missing.empty?

    unless claim_review!
      return redirect_to root_path, alert: "A review is already being generated for this — check back in a moment."
    end

    # Recompute after reload to close the race: another request may have
    # finished the last missing section between our first check and the claim.
    missing = @response.section_keys - Array(@response.ai_review&.keys)
    if missing.empty?
      release_review_claim!
      return redirect_to history_anchor, notice: "Already reviewed."
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
        ConceptMastery.record_review!(@response, sections: successes.keys, apply_session_countdown: first_batch)
      end
      @response.review_errors = @response.review_errors
                                          .except(*successes.keys)
                                          .merge(failures.transform_values { |r| { "code" => r[:error_code], "message" => r[:message] } })
      @response.save!
    end
    release_review_claim!
    clear_stale_generation_error! if successes.any?
    log_review_diagnostics(@response, successes.keys) if successes.any?

    if failures.empty?
      redirect_to history_anchor, notice: "Review ready!"
    elsif successes.any?
      redirect_to root_path, notice: "#{successes.size} of #{missing.size} sections reviewed — #{failures.size} couldn't be reviewed, try again."
    else
      redirect_to root_path, alert: zero_success_alert(failures)
    end
  rescue ActiveRecord::RecordNotFound
    redirect_to root_path, alert: "This set was cleared while the review was running — nothing was saved."
  rescue AiService::AuthenticationError
    release_review_claim!
    redirect_to root_path, alert: "Your API key was rejected — check it in Settings."
  rescue AiService::RateLimitError
    release_review_claim!
    redirect_to root_path, alert: "The AI provider is rate-limiting requests — try again shortly."
  rescue AiService::Error => e
    release_review_claim!
    redirect_to root_path, alert: "Couldn't generate the review: #{e.message}"
  end

  # DELETE /responses/:id/start_over — abandon today's saved answers, ratings,
  # and feedback so the same problem set can be re-attempted from a blank
  # state. Destroys the row outright rather than clearing fields in place —
  # #create's find_or_initialize_by already handles a missing row cleanly, so
  # the next autosave just creates a fresh one with no special-casing needed
  # anywhere else. Hard-blocked once any section has been reviewed: from that
  # point ConceptMastery.record_review! has already moved real tier/streak
  # state for that concept, and this action has no way to undo that. Also
  # blocked while a review is actively claimed: #review's provider call runs
  # outside a transaction, so destroying the row mid-flight lets its
  # ConceptMastery writes commit against a response that no longer exists.
  def start_over
    return redirect_to root_path, alert: "This set has already been reviewed — nothing to start over." if @response.reviewed?
    return redirect_to root_path, alert: "You can only start over on today's set." unless @response.date == Date.current
    return redirect_to root_path, alert: "A review is being generated for this — try again in a moment." if @response.reviewing?

    @response.destroy
    redirect_to root_path, notice: "Today's answers have been cleared — start fresh whenever you're ready."
  end

  # POST /responses/:id/email_review — email the completed review to the user.
  # Both redirects go to root_path: the email button only ever renders on the
  # dashboard's submitted state (_submission.html.erb), not on history, so
  # that's the only page where the user can repeat or confirm the action.
  def email_review
    return redirect_to root_path, alert: "No review to email yet." unless @response.fully_reviewed?

    ReviewMailer.send_review(@response).deliver_later
    redirect_to root_path, notice: "Review sent to #{current_user.email}."
  end

  # PATCH /responses/:id/self_explanation — save the user's own one-sentence
  # explanation of why a fix works. Capture only: nothing grades it, and it gates
  # nothing. Writing to an arbitrarily old response is intentional — /history is
  # where reviews live, so this is where the prompt is answered.
  def self_explanation
    text = params[:text].to_s.strip
    saved = true
    errors = nil

    # No AI call here, so the lock is held only for a fast read-merge-write —
    # unlike explain_differently/follow_ups there's nothing slow to keep
    # outside it. Without this, two tabs saving different sections at once
    # each hold their own stale in-memory hash, and the last save wins,
    # silently dropping the other tab's section.
    @response.with_lock do
      @response.self_explanations = @response.self_explanations.merge(
        @section => text
      )
      saved = @response.save
      errors = @response.errors.full_messages.to_sentence unless saved
    end

    if saved
      render json: { status: "saved" }
    else
      render_section_error(errors)
    end
  end

  # POST /responses/:id/explain_differently — one section's feedback, reframed.
  # Synchronous like #review; the caller posts via fetch and appends in place.
  def explain_differently
    existing = Array(@response.review_alternates[@section])
    if existing.size >= DailyResponse::MAX_ALTERNATES_PER_SECTION
      return render_section_error("You've already asked for #{DailyResponse::MAX_ALTERNATES_PER_SECTION} alternate explanations here.")
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
      render_section_error("You've already asked for #{DailyResponse::MAX_ALTERNATES_PER_SECTION} alternate explanations here.")
    else
      render json: { status: "ok", alternate: alternate, remaining: remaining }
    end
  rescue AiService::Error => e
    render json: { status: "error", error: e.message }, status: :service_unavailable
  end

  # POST /responses/:id/follow_ups — ask one clarifying question about a section's
  # review. Synchronous: a single short completion, so it needs no job or polling.
  # Both turns are written in one transaction, so a provider failure can never
  # leave an orphaned question with no answer in the thread.
  def follow_ups
    question = params[:question].to_s.strip
    return render_section_error("Ask a question first.") if question.blank?

    asked = @response.review_follow_ups.where(section: @section, role: :user).count
    if asked >= DailyResponse::MAX_FOLLOW_UPS_PER_SECTION
      return render_section_error("You've used all #{DailyResponse::MAX_FOLLOW_UPS_PER_SECTION} follow-ups for this section.")
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
      render_section_error("You've used all #{DailyResponse::MAX_FOLLOW_UPS_PER_SECTION} follow-ups for this section.")
    else
      render json: { status: "ok", answer: answer, remaining: remaining }
    end
  rescue AiService::Error => e
    render json: { status: "error", error: e.message }, status: :service_unavailable
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
    return render json: { status: "error", error: "No exercise set for today." }, status: :not_found unless exercise

    section = params[:section].to_s
    # #active_section_keys, not the raw payload keys: a payload can hold a
    # third- or fourth-shaped key the page never rendered, and a section the
    # engineer cannot see is not one they can think out loud about.
    return render_section_error("That section isn't part of this exercise.") unless exercise.active_section_keys.include?(section)

    existing = current_user.daily_responses.find_by(daily_exercise: exercise, date: Date.current)
    return render_section_error("The thinking partner is only available before you submit.") if existing&.submitted?

    message = params[:message].to_s.strip
    return render_section_error("Say something first.") if message.blank?
    if message.length > MAX_DUCK_MESSAGE_LENGTH
      return render_section_error("That message is too long — keep it under #{MAX_DUCK_MESSAGE_LENGTH} characters.")
    end

    thread = duck_thread_param
    if thread.size > MAX_DUCK_THREAD_ENTRIES ||
       thread.sum { |turn| turn[:content].bytesize } > MAX_DUCK_THREAD_BYTES
      return render_section_error("This conversation is too long to continue — clear it to keep going.")
    end
    # Soft, request-level cap: the thread lives only in the browser, so this
    # is not a hardened boundary (a hand-crafted request could understate its
    # own history) — acceptable given each user pays for their own provider
    # calls with their own key. See the design doc's "Cap on exchanges".
    if thread.count { |turn| turn[:role] == "user" } >= MAX_DUCK_TURNS_PER_SECTION
      return render_section_error("You've used all #{MAX_DUCK_TURNS_PER_SECTION} messages for this section — clear the conversation to keep going.")
    end

    answer = AiService.for(current_user).duck_response(
      current_user, exercise, section: section, message: message, thread: thread
    )

    render json: { status: "ok", answer: answer }
  rescue AiService::Error => e
    render json: { status: "error", error: e.message }, status: :service_unavailable
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
    render json: { status: "error", error: e.message }, status: :service_unavailable
  end

  # POST /responses/pseudocode_translate — round 2. Never gated on round 1:
  # whatever plan exists is translated, so there is no way to get stuck.
  def pseudocode_translate
    return unless (context = load_pseudocode_context)

    row, section, pseudocode = context
    return render_section_error(translate_busy_message(row, section)) unless claim_pseudocode_round!(row, section, "translate", :translated?)

    code = AiService.for(current_user).translate_pseudocode(
      current_user, row.daily_exercise, section: section, pseudocode: pseudocode
    )

    write_pseudocode_round!(row, section, "translate",
      "generated_code"  => code,
      "translated_from" => pseudocode,
      "translated_at"   => Time.current.iso8601)

    render json: { status: "ok", code: code }
  rescue AiService::Error => e
    release_pseudocode_claim!(row, section, "translate")
    render json: { status: "error", error: e.message }, status: :service_unavailable
  end

  private

  # A non-Hash-like element (e.g. thread: ["oops"] or thread: "not-an-array",
  # which Array() wraps as a one-element array) would otherwise raise
  # TypeError on turn[:role] and surface as a raw 500 instead of the 422
  # every other bad-input path in this action returns.
  # Roles are normalized to lowercase and restricted to user/assistant — the
  # cap check below matches turn[:role] == "user" exactly, so an unnormalized
  # "User"/"USER" would silently dodge the cap, and AiService#duck_response's
  # thread rendering would mislabel the speaker for anything it doesn't
  # recognize as exactly "assistant".
  def duck_thread_param
    # first(...+1) bounds the mapping itself while still leaving an
    # over-limit thread detectably over limit for the caller's size check.
    Array(params[:thread]).first(MAX_DUCK_THREAD_ENTRIES + 1).filter_map { |turn|
      next unless turn.is_a?(Hash) || turn.respond_to?(:permit)

      role = turn[:role].to_s.downcase
      next unless %w[user assistant].include?(role)

      { role: role, content: turn[:content].to_s }
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
      render json: { status: "error", error: "No exercise set for today." }, status: :not_found
      return
    end

    section = ExerciseSection::PseudocodeToCode.key
    return pseudocode_error("Today's set has no pseudocode section.") unless exercise.active_section_keys.include?(section)

    pseudocode = validated_pseudocode or return
    row        = open_response_for(exercise) or return

    [ row, section, pseudocode ]
  end

  def validated_pseudocode
    value = params[:pseudocode].to_s.strip
    return pseudocode_error("Write your pseudocode first.") if value.blank?
    return pseudocode_error("That's too long — keep it under #{MAX_PSEUDOCODE_LENGTH} characters.") if value.length > MAX_PSEUDOCODE_LENGTH

    value
  end

  # Persisted, because the row lock the rounds claim under needs a real row.
  # Reached only after the request has otherwise validated, so a malformed
  # request never creates one.
  def open_response_for(exercise)
    row = persisted_response_for(exercise)
    return pseudocode_error("The rounds are only available before you submit.") if row.submitted?

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

      merge_pseudocode_round!(row, section, "#{phase}_claimed_at" => Time.current.iso8601)
      claimed = true
    end

    claimed
  end

  # Writing the result also releases the claim, so the two can never disagree.
  def write_pseudocode_round!(row, section, phase, attrs)
    row.with_lock { merge_pseudocode_round!(row, section, attrs.merge("#{phase}_claimed_at" => nil)) }
  end

  # A handled provider failure hands the round back rather than burning it: the
  # engineer paid for nothing, so they should be able to retry immediately
  # instead of waiting out the stale window.
  def release_pseudocode_claim!(row, section, phase)
    return if row.nil?

    row.with_lock { merge_pseudocode_round!(row, section, "#{phase}_claimed_at" => nil) }
  end

  def merge_pseudocode_round!(row, section, attrs)
    rounds          = row.pseudocode_rounds.deep_dup
    rounds[section] = (rounds[section] || {}).merge(attrs).compact
    row.update!(pseudocode_rounds: rounds)
  end

  def critique_busy_message(row, section)
    row.critiqued?(section) ? "You've already had this plan checked." : "A check of this plan is already running."
  end

  def translate_busy_message(row, section)
    row.translated?(section) ? "This plan has already been translated." : "A translation of this plan is already running."
  end

  # render_section_error returns the rendered response, which is truthy; the
  # callers above need a falsy value to mean "already handled".
  def pseudocode_error(message)
    render_section_error(message)
    nil
  end

  # Errors send the user back to the dashboard, where the retry button lives.
  # review's non-error redirects land on the history entry for the day in
  # question; email_review always goes to root_path (see above).
  #
  # History is paginated, so the anchor only resolves if the request lands on
  # the page holding that entry.
  def history_anchor
    history_page_path(@response.history_page, anchor: "response-#{@response.id}")
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
    return render_section_error("That section isn't part of this exercise.") unless @response.daily_exercise.problem_set.key?(@section)
    render_section_error("No review to attach that to yet.") unless @response.section_reviewed?(@section)
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
    return unless current_user.last_generation_error_date == Date.current

    current_user.update!(last_generation_error_date: nil, last_generation_error: nil)
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
    missed    = DailyResponse.review_points(response.ai_review&.dig(section, "missed")).size

    Rails.logger.info(
      "[pseudocode] user=#{response.user_id} date=#{response.daily_exercise.date} phase=review " \
      "critiqued=#{critiqued} gaps=#{gaps} missed=#{missed} " \
      "disagreement=#{critiqued && gaps.zero? && missed.positive?}"
    )
  end

  def zero_success_alert(failures)
    codes = failures.values.map { |f| f[:error_code] }.uniq
    case codes
    in [ "authentication" ]
      "Your API key was rejected — check it in Settings."
    in [ "rate_limit" ]
      "The AI provider is rate-limiting requests — try again shortly."
    else
      "Couldn't generate the review: #{failures.values.first[:message]}"
    end
  end

  def response_params
    @response_params ||= params.require(:response).permit(
      :submit, :feedback_text,
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
