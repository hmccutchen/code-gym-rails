# A provider error's message can carry provider text, so only a SetupError's, which the app writes, is read here, to log it.
module ProviderFailureRendering
  extend ActiveSupport::Concern

  private

  def provider_failure_text(error, surface)
    Rails.logger.error("Setup error for user #{current_user.id} on #{surface}: #{error.message}") if error.is_a?(SetupError)
    ProviderFailureText.new(ProviderFailure.classify(error), provider: current_user.provider, surface: surface,
                            failed_at: Time.current, zone: current_user.effective_time_zone,
                            retry_after: error.try(:retry_after), variant: ProviderFailureText.variant_for(current_user))
  end

  def render_provider_failure(error, surface)
    text = provider_failure_text(error, surface)
    render_json_error(text.brief, status: :service_unavailable, failure: text.kind)
  end
end
