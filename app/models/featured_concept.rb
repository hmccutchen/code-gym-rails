# One concept per user per week, picked on the first visit and read by every visit after it.
class FeaturedConcept < ApplicationRecord
  belongs_to :user

  def self.week_of(date)
    date.beginning_of_week(:monday)
  end

  def self.for(user, today: Date.current)
    week   = week_of(today)
    stored = user.featured_concepts.find_by(week_of: week)
    return stored if stored&.fits?(user.language)

    pair = pick_for(user, week, today)
    if pair.nil?
      stored&.destroy
      return
    end
    return stored.tap { |row| row.update!(concept: pair.first, bucket: pair.last) } if stored

    claim(user, week, pair)
  end

  # Savepoint so the unique index's RecordNotUnique rolls back only this insert and the re-read can see the winner.
  def self.claim(user, week, (concept, bucket))
    transaction(requires_new: true) { user.featured_concepts.create!(week_of: week, concept: concept, bucket: bucket) }
  rescue ActiveRecord::RecordNotUnique
    user.featured_concepts.find_by(week_of: week)
  end
  private_class_method :claim

  def self.pick_for(user, week, today)
    met = met_concepts(user, today)
    return if met.empty?

    history = user.featured_concepts.where.not(week_of: week).order(:week_of).pluck(:concept, :bucket, :week_of)
    FeaturedConceptPick.pick(
      met: met, ledger: RungLedger.for(user),
      last_featured: history.to_h { |concept, bucket, shown| [ [ concept, bucket ], shown ] },
      previous: history.find { |_concept, _bucket, shown| shown == week - 7 }&.first(2)
    )
  end
  private_class_method :pick_for

  def self.met_concepts(user, today)
    ConceptBucket.slice_for(user.language).flat_map do |bucket|
      ConceptBucket.vocabulary_for(bucket).filter_map do |concept|
        [ concept, bucket ] if user.concept_exposure_count(concept, bucket, on_or_before: today).positive?
      end
    end
  end
  private_class_method :met_concepts

  # The one rule for marking a section with this week's concept; any later fade rule belongs here.
  def marks?(concept:, bucket:)
    self.concept == concept && self.bucket == bucket
  end

  def fits?(language)
    ConceptBucket.slice_for(language).include?(bucket) && ConceptBucket.vocabulary_for(bucket).include?(concept)
  end
end
