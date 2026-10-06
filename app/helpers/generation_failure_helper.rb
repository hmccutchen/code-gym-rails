module GenerationFailureHelper
  # A provider failure is a whole sentence group that names the set itself;
  # any other stored message (a kept reviewed set, an unusable draft) is a
  # clause written to follow the "Couldn't generate a new set" prefix.
  def regeneration_failure_line(user)
    message = user.generation_failure_message(surface: :regeneration)
    user.last_generation_failure.present? ? message : t("dashboard.exercise.regeneration_failed", error: message)
  end

  # The newest stored review failure, as the sentence its kind earns today.
  # Rows written before kinds were stored carry a code instead and read as the
  # nearest kind.
  LEGACY_REVIEW_CODES = { "rate_limit" => "short_rate_limit", "authentication" => "bad_key" }.freeze

  def review_failure_sentence(response)
    failure = response.review_errors.values.max_by { |entry| entry["at"].to_s }
    return if failure.nil?

    kind = failure["kind"] || LEGACY_REVIEW_CODES.fetch(failure["code"], "other")
    failed_at = failure["at"].present? ? Time.zone.parse(failure["at"]) : response.updated_at
    ProviderFailureText.new(kind, provider: response.user.provider, surface: :review, failed_at: failed_at,
                            zone: response.user.effective_time_zone, retry_after: failure["retry_after"]).full
  end
end
