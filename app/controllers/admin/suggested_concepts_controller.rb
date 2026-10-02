module Admin
  class SuggestedConceptsController < Admin::BaseController
    def index
      @suggested_concepts = SuggestedConcept.where(status: "pending").order(occurrences: :desc)
      @referenced_keys = ConceptReference.where(language: @suggested_concepts.map(&:language))
                                          .pluck(:language, :concept).to_set
    end

    def promote
      concept = SuggestedConcept.find(params[:id])

      unless ConceptReference.exists?(language: concept.language, concept: concept.normalized_name)
        return redirect_to admin_suggested_concepts_path, alert: t("flash.admin.suggested_concepts.reference_missing")
      end

      concept.update!(status: "promoted", reviewed_at: Time.current, reviewed_by: current_user)
      redirect_to admin_suggested_concepts_path, notice: t("flash.admin.suggested_concepts.promoted", name: concept.display_name)
    end

    def dismiss
      concept = SuggestedConcept.find(params[:id])
      concept.update!(status: "dismissed", reviewed_at: Time.current, reviewed_by: current_user)
      redirect_to admin_suggested_concepts_path, notice: t("flash.admin.suggested_concepts.dismissed", name: concept.display_name)
    end
  end
end
