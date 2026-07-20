module Admin
  class SuggestedConceptsController < Admin::BaseController
    def index
      @suggested_concepts = SuggestedConcept.where(status: "pending").order(occurrences: :desc)
    end

    def promote
      concept = SuggestedConcept.find(params[:id])

      unless ConceptReference.exists?(language: concept.language, concept: concept.normalized_name)
        return redirect_to admin_suggested_concepts_path, alert: "Add a ConceptReference for this concept first."
      end

      concept.update!(status: "promoted", reviewed_at: Time.current, reviewed_by: current_user)
      redirect_to admin_suggested_concepts_path, notice: "Marked #{concept.display_name} as promoted."
    end

    def dismiss
      concept = SuggestedConcept.find(params[:id])
      concept.update!(status: "dismissed", reviewed_at: Time.current, reviewed_by: current_user)
      redirect_to admin_suggested_concepts_path, notice: "Dismissed #{concept.display_name}."
    end
  end
end
