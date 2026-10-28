# Design notes: docs/code-notes/app/models/concept_exposure_index.md
class ConceptExposureIndex
  def self.for(user)
    dates = Hash.new { |hash, key| hash[key] = Set.new }
    user.daily_responses.where.not(submitted_at: nil).joins(:daily_exercise)
        .pluck(:date, :concept_tags, "daily_exercises.language")
        .each do |date, tags, language|
      (tags || {}).each do |section, concept|
        key = key_for(section, concept, language)
        dates[key] << date if key
      end
    end
    new(dates)
  end

  def self.counted?(concept) = concept.present? && concept != "other"

  def self.key_for(section, concept, language)
    [ concept, ConceptBucket.for(section, language) ] if counted?(concept)
  end

  def initialize(dates)
    @dates = dates
  end

  def count(concept, bucket, on_or_before:)
    dates_for(concept, bucket).count { |date| date <= on_or_before }
  end

  def count_for(section, concept, language, on_or_before:)
    key = self.class.key_for(section, concept, language)
    count(*key, on_or_before: on_or_before) if key
  end

  def last_seen(concept, bucket)
    dates_for(concept, bucket).max
  end

  private

  def dates_for(concept, bucket) = @dates.fetch([ concept, bucket ], Set.new)
end
