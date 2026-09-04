class ConceptReferencesController < ApplicationController
  # How many alternate framings of one concept a single page-view may ask for.
  # Two is enough to find an angle that lands; past that the trouble is the
  # concept's difficulty rather than the wording, and the mastery loop is what
  # answers that.
  #
  # Lives on the controller rather than on ConceptReference for the reason
  # documented at ResponsesController::MAX_DUCK_TURNS_PER_SECTION: this feature
  # owns no model data at all. Deliberately not derived from
  # DailyResponse::MAX_ALTERNATES_PER_SECTION despite the equal value — that
  # one bounds framings of one section's feedback, this one framings of one
  # durable concept, and coupling them would make either un-tunable.
  MAX_ALTERNATES_PER_CONCEPT = 2

  # Bounds what a crafted request can forward to the provider. Two framings of
  # CONCEPT_ALTERNATE_MAX_TOKENS each, with room to spare, in bytes because it
  # bounds a payload and one character is up to four.
  MAX_PRIOR_ALTERNATE_BYTES = 8_000

  # POST /concept_references/:id/explain_differently — the same concept,
  # explained another way, for someone the cached reference did not land for.
  #
  # Fully unpersisted: no row is created or written, here or anywhere. The
  # framings already shown live in the tab that asked for them and are sent
  # back on each request purely as prompt context, exactly as the duck thread
  # does. The shared ConceptReference is read and never touched, so one
  # engineer asking for another angle cannot change what a teammate reads.
  #
  # Synchronous like ResponsesController#explain_differently: one short prose
  # completion the caller posts by fetch and appends in place, so there is
  # nothing for a job and polling to buy.
  def explain_differently
    reference = ConceptReference.find(params[:id])
    prior = prior_alternates_param

    if prior.size >= MAX_ALTERNATES_PER_CONCEPT
      return render_error("You've already asked for #{MAX_ALTERNATES_PER_CONCEPT} other framings of this concept.")
    end
    if prior.sum(&:bytesize) > MAX_PRIOR_ALTERNATE_BYTES
      return render_error("That's more explanation than this can carry — reload the page to start fresh.")
    end

    alternate = AiService.for(current_user).explain_concept_differently(
      current_user, reference, prior_alternates: prior
    )

    render json: { status: "ok", alternate: alternate,
                   remaining: MAX_ALTERNATES_PER_CONCEPT - prior.size - 1 }
  rescue ActiveRecord::RecordNotFound
    # A JSON body, not the default HTML 404: the client's fetch handler calls
    # res.json() before checking res.ok, so an HTML page would surface as a
    # parse error instead of a clean message (same reasoning as
    # ResponsesController#duck_thread's missing-exercise branch).
    render json: { status: "error", error: "That reference no longer exists." }, status: :not_found
  rescue AiService::Error => e
    render json: { status: "error", error: e.message }, status: :service_unavailable
  end

  private

  # The framings the client says it has already been shown. Soft, request-level
  # like the duck thread's cap: a hand-crafted request could understate its own
  # history and ask again, which is acceptable because each user spends their
  # own provider key. What this does hold is the size of what reaches the
  # provider, and that a non-string element can't raise past the guards above.
  # first(MAX + 1) bounds the mapping while still leaving an over-cap list
  # detectably over cap.
  def prior_alternates_param
    Array(params[:prior_alternates]).first(MAX_ALTERNATES_PER_CONCEPT + 1)
                                    .filter_map { |framing| framing.to_s.presence if framing.is_a?(String) }
  end

  def render_error(message)
    render json: { status: "error", error: message }, status: :unprocessable_content
  end
end
