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
    @ladder_targets = ladder_targets_for(@reference)
    @ladder_missing = @ladder_targets.any? && params[:ladder] == "missing"
  end

  # Which check the polling page is waiting on. The page states it because the
  # row's current state cannot: once a no-guide page's guide lands, the row looks
  # like a ladder candidate, and a flubbed ladder would then never read ready.
  # Absent reads as guide, the only value pages sent before this existed.
  AWAITING = { "guide" => :guide?, "ladder" => :complete? }.freeze
  GENERATION_VERSION_FORMAT = /\A\d+\z/

  # GET /learn/:bucket/:concept/status — is the write-up the page asked for done?
  #
  # Same shape and same reason as DashboardController#status. A fixed client
  # timeout would have to guess how long a provider call takes, and this one
  # runs with extended thinking on, so the guess would be wrong in both
  # directions — reloading onto an unfinished page, or waiting long after it
  # finished.
  def status
    bucket    = validated_bucket
    concept   = validated_concept(bucket)
    awaiting  = params.fetch(:awaiting, "guide").to_s
    predicate = AWAITING[awaiting]
    return head :bad_request if predicate.nil?
    return head :bad_request if awaiting == "ladder" && !params[:generation_version].to_s.match?(GENERATION_VERSION_FORMAT)

    reference = ConceptReference.find_by(concept: concept, language: bucket)
    body = { ready: reference&.public_send(predicate) || false }
    if awaiting == "ladder"
      body[:rewritten] = reference.present? && reference.generation_version > params[:generation_version].to_i
    end

    render json: body
  end

  # POST /learn/:bucket/:concept/prepare — write up this one concept now.
  #
  # `refresh: true` permits a whole-row rewrite for this concept. The backfill
  # keeps existing rows; #prepare_ladders is the scoped bulk exception.
  #
  # JSON, since only script calls it: the page posts and polls rather than
  # holding a request open for a provider call that runs with thinking on.
  def prepare_concept
    bucket  = validated_bucket
    concept = validated_concept(bucket)

    GenerateConceptReferenceJob.perform_later(
      concept: concept, language: bucket, user_id: current_user.id, refresh: true
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

  # POST /learn/prepare_ladders — ground every targeted kind's concepts.
  #
  # Unlike #prepare, this rewrites existing rows, which is the scoped exception
  # to the no-bulk-rewrite rule: only concepts behind a target this user set, and
  # only from a click whose copy says wording may change. Rows are shared, so
  # the rewrite reaches every teammate. Gaps are re-derived each press; the
  # job's queue permit discards overlaps and complete? skips finished rows.
  def prepare_ladders
    gaps = LadderCoverage.for(current_user).gaps_for(KindDifficulty.for(current_user).targeted_kinds)

    gaps.each do |concept, bucket|
      GenerateConceptReferenceJob.perform_later(concept: concept, language: bucket, user_id: current_user.id, refresh: true)
    end

    redirect_to setup_path(anchor: "exercise-mix"), notice: t("exercise_mix.ladders_preparing", count: gaps.size)
  end

  private

  # Names of the targeted kinds a guided, ladderless row would ground. Empty
  # means no rewrite is offered: the ladder would ground nothing for this user.
  def ladder_targets_for(reference)
    return [] unless reference&.guide? && !reference.ladder?

    kinds = KindDifficulty.for(current_user).targeted_kinds
    return [] if kinds.empty?

    LadderCoverage.for(current_user).grounding_kinds(kinds, reference.concept, reference.language)
                  .map { |kind| t("sections.#{kind.key}.name") }
  end

  # This user's slice: their language's buckets plus every language-independent
  # bucket.
  def learn_buckets
    ConceptBucket.language_buckets_for(current_user.language) + ConceptBucket::LANGUAGE_INDEPENDENT
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
