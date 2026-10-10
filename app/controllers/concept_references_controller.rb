class ConceptReferencesController < ApplicationController
  include ProviderCallLimits
  include ProviderFailureRendering

  limit_provider_calls only: :explain_differently

  # Equal to DailyResponse::MAX_ALTERNATES_PER_SECTION by coincidence; they bound different things, so keep them separate.
  MAX_ALTERNATES_PER_CONCEPT = 2

  # Bounds what a crafted request can forward: two framings with room to spare, in bytes since a character is up to four.
  MAX_PRIOR_ALTERNATE_BYTES = 8_000

  # POST /concept_references/:id/explain_differently — unpersisted; the shared reference is read, never written.
  def explain_differently
    reference = ConceptReference.find(params[:id])
    prior = prior_alternates_param

    if prior.size >= MAX_ALTERNATES_PER_CONCEPT
      return render_error(t("errors.concept_references.framings_used", count: MAX_ALTERNATES_PER_CONCEPT))
    end
    if prior.sum(&:bytesize) > MAX_PRIOR_ALTERNATE_BYTES
      return render_error(t("errors.concept_references.too_much_explanation"))
    end

    alternate = AiService.for(current_user).explain_concept_differently(
      current_user, reference, prior_alternates: prior
    )

    render json: { status: "ok", alternate: alternate,
                   remaining: MAX_ALTERNATES_PER_CONCEPT - prior.size - 1 }
  rescue ActiveRecord::RecordNotFound
    # A JSON body because the client calls res.json() before checking res.ok.
    render json: { status: "error", error: t("errors.concept_references.reference_missing") }, status: :not_found
  rescue AiService::Error => e
    render_provider_failure(e, :alternate)
  end

  private

  # Soft cap, since each user spends their own key; first(MAX + 1) keeps an over-cap list detectably over the cap.
  def prior_alternates_param
    Array(params[:prior_alternates]).first(MAX_ALTERNATES_PER_CONCEPT + 1)
                                    .filter_map { |framing| UserText.normalize(framing).presence if framing.is_a?(String) }
  end

  def render_error(message)
    render json: { status: "error", error: message }, status: :unprocessable_content
  end
end
