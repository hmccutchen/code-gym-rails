class LearnController < ApplicationController
  helper_method :encountered?

  # The four language-independent buckets, from the authority that already
  # names them, so a fifth one added to ConceptBucket appears here without an
  # edit.
  AGNOSTIC_BUCKETS = ConceptBucket::SPECIAL_BUCKETS.values.freeze

  # GET /learn — every concept in this user's vocabularies, grouped, whether or
  # not they have ever been assigned one.
  def index
    @references = references_by_key
    @buckets    = learn_buckets.map do |bucket|
      { key: bucket, groups: ConceptGroup.grouped(ConceptBucket.vocabulary_for(bucket)) }
    end
    @ungenerated = ungenerated_concepts.size
  end

  private

  # This user's slice: their own language plus every language-independent
  # bucket. Reads user.language, NEVER User#language_for_today — that resolves
  # "mixed" to one concrete language for a single day's generation by flipping
  # off the last exercise, and a library must not change contents depending on
  # which language tomorrow happens to be. A mixed user is assigned both, so a
  # mixed user browses both.
  def learn_buckets
    language_buckets + AGNOSTIC_BUCKETS
  end

  # Derived, never a hardcoded pair: LANGUAGE_CONFIG is this app's stated
  # single source of truth per generation language, and adding one there must
  # not require hunting down a ternary here. The programming languages are
  # exactly the config keys that are not language-independent buckets.
  PROGRAMMING_LANGUAGES = (AiService::LANGUAGE_CONFIG.keys - ConceptBucket::SPECIAL_BUCKETS.keys).freeze

  def language_buckets
    current_user.language == "mixed" ? PROGRAMMING_LANGUAGES : [ current_user.language ]
  end

  # One query for every reference the page can render, keyed the way the views
  # look them up. The per-concept finder would be seventy queries.
  def references_by_key
    ConceptReference.where(language: learn_buckets)
                    .index_by { |reference| [ reference.concept, reference.language ] }
  end

  # Concepts with no row at all — exactly what the backfill will generate, and
  # therefore the number its button is allowed to quote. A row that exists
  # without a guide is deliberately NOT counted here: rewriting it in bulk
  # would change inline reference text for concepts nobody asked about, so it
  # is left to the on-demand path.
  def ungenerated_concepts
    learn_buckets.flat_map do |bucket|
      ConceptBucket.vocabulary_for(bucket)
                   .reject { |concept| @references.key?([ concept, bucket ]) }
                   .map { |concept| [ concept, bucket ] }
    end
  end

  # Has this user actually met the concept in a submitted set? Reads the
  # existing memoized exposure index, which counts submitted responses only.
  #
  # Deliberately NOT sourced from ConceptMastery: that holds tier, streak and
  # retention state, which this app keeps invisible everywhere so it cannot
  # shape engagement. "You have seen this" and "how well you did" are different
  # facts, and only the first is shown here.
  def encountered?(concept, bucket)
    current_user.concept_exposure_count(concept, bucket, on_or_before: Date.current).positive?
  end
end
