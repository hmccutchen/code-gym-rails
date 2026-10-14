module GenerationFailureHelper
  # A provider failure is a whole sentence; any other stored message is a clause following the "Couldn't generate" prefix.
  def regeneration_failure_line(user)
    message = user.generation_failure_message(surface: :regeneration)
    user.last_generation_failure.present? ? message : t("dashboard.exercise.regeneration_failed", error: message)
  end

  def review_failure_sentence(response)
    failure = response.review_errors.values.max_by { |entry| entry["at"].to_s }
    return if failure.nil?

    kind = failure["kind"] || "other"
    failed_at = failure["at"].present? ? Time.zone.parse(failure["at"]) : response.updated_at
    surface = response.reviewed? ? :review_partial : :review
    ProviderFailureText.new(kind, provider: failure["provider"] || response.user.provider, surface: surface, failed_at: failed_at,
                            zone: response.user.effective_time_zone, retry_after: failure["retry_after"],
                            variant: ProviderFailureText.variant_for(response.user)).full
  end
end
