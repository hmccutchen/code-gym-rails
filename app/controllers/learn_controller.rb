class LearnController < ApplicationController
  helper_method :encountered?

  # GET /learn — every concept in this user's vocabularies, grouped, whether or
  # not they have ever been assigned one.
  def index
    @featured   = ConceptReference.featured
    @references = references_by_key
    @buckets    = learn_buckets.map do |bucket|
      { key: bucket, groups: ConceptGroup.grouped(ConceptBucket.vocabulary_for(bucket)) }
    end
    @ungenerated = ungenerated_concepts(@references).size
  end

  # GET /learn/:bucket/:concept
  def show
    @bucket    = validated_bucket
    @concept   = validated_concept(@bucket)
    @reference = ConceptReference.find_by(concept: @concept, language: @bucket)
  end

  # GET /learn/:bucket/:concept/status — is the guide written yet?
  #
  # Same shape and same reason as DashboardController#status. A fixed client
  # timeout would have to guess how long a provider call takes, and this one
  # runs with extended thinking on, so the guess would be wrong in both
  # directions — reloading onto an unfinished page, or waiting long after it
  # finished.
  def status
    bucket  = validated_bucket
    concept = validated_concept(bucket)

    render json: { ready: ConceptReference.find_by(concept: concept, language: bucket)&.guide? || false }
  end

  # POST /learn/:bucket/:concept/prepare — write up this one concept now.
  #
  # `refresh_guide: true` is what lets this rewrite a row that predates guides.
  # Confining that to a concept someone deliberately opened is why the
  # backfill below refuses to do it.
  #
  # JSON, since only script calls it: the page posts and polls rather than
  # holding a request open for a provider call that runs with thinking on.
  def prepare_concept
    bucket  = validated_bucket
    concept = validated_concept(bucket)

    GenerateConceptReferenceJob.perform_later(
      concept: concept, language: bucket, user_id: current_user.id, refresh_guide: true
    )

    render json: { status: "queued" }
  end

  # POST /learn/prepare — write up every concept in this user's slice that has
  # no row at all.
  #
  # Idempotent and resumable: each job re-checks before calling, so pressing
  # this again after a partial run enqueues only what is still missing and
  # there is no run record to reconcile. Rows are shared team-wide, so the
  # second person to press it finds almost everything done.
  def prepare
    references = references_by_key

    ungenerated_concepts(references).each do |concept, bucket|
      GenerateConceptReferenceJob.perform_later(concept: concept, language: bucket, user_id: current_user.id)
    end

    redirect_to learn_path, notice: t("learn.preparing")
  end

  private

  # This user's slice: their own language plus every language-independent
  # bucket. Reads user.language, NEVER User#language_for_today — that resolves
  # "mixed" to one concrete language for a single day's generation by flipping
  # off the last exercise, and a library must not change contents depending on
  # which language tomorrow happens to be. A mixed user is assigned both, so a
  # mixed user browses both.
  def learn_buckets
    language_buckets + ConceptBucket::LANGUAGE_INDEPENDENT
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
  def ungenerated_concepts(references)
    learn_buckets.flat_map do |bucket|
      ConceptBucket.vocabulary_for(bucket)
                   .reject { |concept| references.key?([ concept, bucket ]) }
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

  # :bucket and :concept arrive from a URL, so they are held to the closed
  # vocabulary here rather than trusted downstream — the same boundary rule
  # ProblemSetIngest applies to provider output. An unknown pair is a 404, not
  # a page rendering an empty concept.
  #
  # Validating the bucket against learn_buckets rather than every bucket also
  # means a user cannot browse the language they are not assigned by typing
  # the URL, which keeps the page and its address saying the same thing.
  def validated_bucket
    bucket = params[:bucket].to_s
    raise ActiveRecord::RecordNotFound unless learn_buckets.include?(bucket)

    bucket
  end

  def validated_concept(bucket)
    concept = params[:concept].to_s
    raise ActiveRecord::RecordNotFound unless ConceptBucket.vocabulary_for(bucket).include?(concept)

    concept
  end
end
