class LearnController < ApplicationController
  include LearnScope

  helper_method :encountered?

  # Counted per press, not per job: each press queues one billed job per missing concept.
  PREPARE_PER_HOUR = 10

  rate_limit to: PREPARE_PER_HOUR, within: 1.hour, by: -> { current_user.id }, with: -> { preparing_limited },
             store: LazyCacheStore.new, name: "prepare", only: [ :prepare, :prepare_ladders, :prepare_concept ],
             unless: :own_key?

  # GET /learn — every concept in this user's vocabularies, assigned or not.
  def index
    @featured   = ConceptReference.featured
    @references = references_by_key
    @drills     = ConceptDrills.for(current_user)
    @buckets    = learn_buckets.map do |bucket|
      { key: bucket, groups: ConceptGroup.grouped(ConceptBucket.vocabulary_for(bucket)) }
    end
    @ungenerated = ungenerated_concepts(@references).size
    @recognition_guides = RecognitionGuide.where(group_key: recognition_group_keys).index_by(&:group_key)
    @ungenerated_guides = recognition_group_keys.size - @recognition_guides.size
  end

  # GET /learn/:bucket/:concept
  def show
    @bucket    = validated_bucket
    @concept   = validated_concept(@bucket)
    @reference = ConceptReference.find_by(concept: @concept, language: @bucket)
    @ladder_targets = ladder_targets_for(@reference)
    @ladder_missing = @ladder_targets.any? && params[:ladder] == "missing"
    @lesson_missing = @reference.present? && !@reference.lesson? && params[:lesson] == "missing"
    @drills = ConceptDrills.for(current_user)
    @paused = current_user.concept_masteries.tier_paused.exists?(concept: @concept, language: @bucket)
  end

  # The page names its check because the row can't: a landed guide makes it look like a ladder candidate. Absent = guide.
  AWAITING = { "guide" => :guide?, "ladder" => :complete?, "lesson" => :lesson? }.freeze
  # The page's seen version lets the poll tell a finished rewrite that lacks the asked-for part from queued work.
  AWAITING_REWRITE = %w[ladder lesson].freeze
  GENERATION_VERSION_FORMAT = /\A\d+\z/

  # GET /learn/:bucket/:concept/status — polled because a fixed timeout can't guess a thinking-on provider call.
  def status
    bucket    = validated_bucket
    concept   = validated_concept(bucket)
    awaiting  = params.fetch(:awaiting, "guide").to_s
    predicate = AWAITING[awaiting]
    return head :bad_request if predicate.nil?
    return head :bad_request if AWAITING_REWRITE.include?(awaiting) && !params[:generation_version].to_s.match?(GENERATION_VERSION_FORMAT)

    reference = ConceptReference.find_by(concept: concept, language: bucket)
    body = { ready: reference&.public_send(predicate) || false }
    if AWAITING_REWRITE.include?(awaiting)
      body[:rewritten] = reference.present? && reference.generation_version > params[:generation_version].to_i
    end
    body.merge!(write_up_failure(concept, bucket)) unless body[:ready]

    render json: body
  end

  # POST /learn/:bucket/:concept/prepare — JSON for the page's script; refresh: true permits a whole-row rewrite.
  def prepare_concept
    bucket  = validated_bucket
    concept = validated_concept(bucket)

    # Clear an earlier failure note, or it would answer this attempt's first poll before the job runs.
    ConceptReferenceFailures.clear(user_id: current_user.id, concept: concept, language: bucket)
    GenerateConceptReferenceJob.perform_later(
      concept: concept, language: bucket, user_id: current_user.id, refresh: true
    )

    render json: { status: "queued" }
  end

  # POST /learn/prepare — idempotent: each job re-checks, so a second press enqueues only what is still missing.
  def prepare
    references = references_by_key

    ungenerated_concepts(references).each do |concept, bucket|
      GenerateConceptReferenceJob.perform_later(concept: concept, language: bucket, user_id: current_user.id)
    end

    missing_recognition_guides.each do |group_key|
      GenerateRecognitionGuideJob.perform_later(group_key: group_key, user_id: current_user.id)
    end

    redirect_to learn_path, notice: t("learn.preparing")
  end

  # POST /learn/prepare_ladders — the scoped exception to no bulk rewrites; shared rows change for every teammate.
  def prepare_ladders
    gaps = LadderCoverage.for(current_user).gaps_for(KindDifficulty.for(current_user).targeted_kinds)

    gaps.each do |concept, bucket|
      GenerateConceptReferenceJob.perform_later(concept: concept, language: bucket, user_id: current_user.id, refresh: true)
    end

    redirect_to setup_path(anchor: "exercise-mix"), notice: t("exercise_mix.ladders_preparing", count: gaps.size)
  end

  private

  # Within ConceptReferenceFailures::EXPIRY; the page stops polling on a failure.
  def write_up_failure(concept, bucket)
    failure = ConceptReferenceFailures.read(user_id: current_user.id, concept: concept, language: bucket)
    return {} if failure.nil?

    text = ProviderFailureText.new(failure["kind"], provider: failure["provider"] || current_user.provider, surface: :reference,
                                   failed_at: Time.zone.parse(failure["at"].to_s), zone: current_user.effective_time_zone,
                                   retry_after: failure["retry_after"], variant: ProviderFailureText.variant_for(current_user))
    { failed: text.kind, message: text.brief }
  end

  def preparing_limited
    message = t("learn.preparing_limited")
    return render json: { status: "error", error: message }, status: :too_many_requests if request.format.json?

    redirect_back fallback_location: learn_path, alert: message
  end

  # Empty means no rewrite is offered: the ladder would ground nothing for this user.
  def ladder_targets_for(reference)
    return [] unless reference&.guide? && !reference.ladder?

    kinds = KindDifficulty.for(current_user).targeted_kinds
    return [] if kinds.empty?

    LadderCoverage.for(current_user).grounding_kinds(kinds, reference.concept, reference.language)
                  .map { |kind| t("sections.#{kind.key}.name") }
  end

  # One query for every renderable reference; the per-concept finder would be one query per concept.
  def references_by_key
    ConceptReference.where(language: learn_buckets)
                    .index_by { |reference| [ reference.concept, reference.language ] }
  end

  # Counts only rows that don't exist; bulk-rewriting guideless rows would change text nobody asked about.
  def ungenerated_concepts(references)
    learn_buckets.flat_map do |bucket|
      ConceptBucket.vocabulary_for(bucket)
                   .reject { |concept| references.key?([ concept, bucket ]) }
                   .map { |concept| [ concept, bucket ] }
    end
  end

  # The recognition groups whose blocks this user's index renders.
  def recognition_group_keys
    @recognition_group_keys ||= learn_buckets.flat_map do |bucket|
      ConceptGroup.grouped(ConceptBucket.vocabulary_for(bucket)).map { |group, _concepts| RecognitionGuide.key_for(bucket, group) }
    end.compact.uniq
  end

  def missing_recognition_guides
    recognition_group_keys - RecognitionGuide.where(group_key: recognition_group_keys).pluck(:group_key)
  end

  # Reads the exposure index, never ConceptMastery: tier state stays invisible everywhere.
  def encountered?(concept, bucket)
    current_user.concept_exposure_count(concept, bucket, on_or_before: Date.current).positive?
  end
end
