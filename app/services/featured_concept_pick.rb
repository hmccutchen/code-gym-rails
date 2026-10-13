# Pure: which met concept a user is shown this week. Design: CLAUDE.md "The weekly featured concept".
class FeaturedConceptPick
  # met: [concept, bucket] pairs in slice order; last_featured: pair => latest week shown; previous: last week's pair.
  def self.pick(met:, ledger:, last_featured:, previous: nil)
    eligible = met.reject { |concept, bucket| held_only?(ledger, concept, bucket) }
    eligible -= [ previous ] if (eligible - [ previous ]).any?
    developing = eligible.select { |concept, bucket| ledger.developing_toward(concept, bucket) }
    pool = developing.presence || eligible

    pool.min_by { |pair| [ last_featured.key?(pair) ? 1 : 0, last_featured.fetch(pair, Date.new), met.index(pair) ] }
  end

  def self.held_only?(ledger, concept, bucket)
    ledger.held(concept, bucket).present? && ledger.developing_toward(concept, bucket).nil?
  end
  private_class_method :held_only?
end
