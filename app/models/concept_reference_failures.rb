# Why the last write-up one user asked for did not land, kept in the Rails
# cache rather than on the ConceptReference row: that row is shared by every
# user, and a failure belongs to the key that hit it. Keyed by user and
# concept, and short-lived: the note exists to stop the page polling and say
# why, and an hour is long past any poll. It is shorter than any quota's reset
# on purpose, so a stale note never outlives the limit it describes.
#
# Web and worker share the production store (Solid Cache in the one Postgres
# database), which is what lets the worker's job write what the web's status
# endpoint reads. Development's memory store is per process, and there the
# jobs run in the web process, so the note still arrives.
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
