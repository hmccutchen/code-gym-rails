# The one way a controller turns a provider error into words for the person
# who hit it: classified, then written in their zone. Nothing here reads the
# error's message.
module ProviderFailureRendering
  extend ActiveSupport::Concern

  private

  def provider_failure_text(error, surface)
    ProviderFailureText.new(ProviderFailure.classify(error), provider: current_user.provider, surface: surface,
                            failed_at: Time.current, zone: current_user.effective_time_zone,
                            retry_after: error.try(:retry_after))
  end

  def render_provider_failure(error, surface)
    text = provider_failure_text(error, surface)
    render json: { status: "error", error: text.brief, failure: text.kind }, status: :service_unavailable
  end
end
