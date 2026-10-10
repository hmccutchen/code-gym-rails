# Per user in the cache, not on the shared row; expires before any quota resets so a note never outlives its limit.
module ConceptReferenceFailures
  EXPIRY = 1.hour

  def self.record(user_id:, concept:, language:, error:)
    Rails.cache.write(key(user_id, concept, language),
                      { "kind" => ProviderFailure.classify(error), "provider" => error.try(:provider),
                        "quota_id" => error.try(:quota_id), "retry_after" => error.try(:retry_after),
                        "at" => Time.current.iso8601 }.compact,
                      expires_in: EXPIRY)
  end

  def self.read(user_id:, concept:, language:)
    Rails.cache.read(key(user_id, concept, language))
  end

  def self.clear(user_id:, concept:, language:)
    Rails.cache.delete(key(user_id, concept, language))
  end

  def self.key(user_id, concept, language)
    "concept_reference_failure/#{user_id}/#{language}/#{concept}"
  end
end
