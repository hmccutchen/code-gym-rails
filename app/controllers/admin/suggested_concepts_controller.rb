module Admin
  class SuggestedConceptsController < Admin::BaseController
    def index
      @suggested_concepts = SuggestedConcept.where(status: "pending").order(occurrences: :desc)
      @referenced_keys = ConceptReference.written_up_keys(languages: @suggested_concepts.map(&:language))
    end

    def promote
      concept = SuggestedConcept.find(params[:id])

      unless ConceptReference.written_up?(language: concept.language, concept: concept.normalized_name)
        return redirect_to admin_suggested_concepts_path, alert: t("flash.admin.suggested_concepts.reference_missing")
      end

      return signed_out unless concept.review!("promoted", reviewer_id: current_user.id)

      redirect_to admin_suggested_concepts_path, notice: t("flash.admin.suggested_concepts.promoted", name: concept.display_name)
    end

    def dismiss
      concept = SuggestedConcept.find(params[:id])
      return signed_out unless concept.review!("dismissed", reviewer_id: current_user.id)

      redirect_to admin_suggested_concepts_path, notice: t("flash.admin.suggested_concepts.dismissed", name: concept.display_name)
    end

    private

    def signed_out
      redirect_to login_path, alert: t("flash.application.login_required")
    end
  end
end
