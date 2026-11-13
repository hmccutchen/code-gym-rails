class LearnController < ApplicationController
  include LearnScope

  helper_method :encountered?, :writes_learn_content?

  def index
    @references = references_by_key
    @drills     = ConceptDrills.for(current_user)
    @buckets    = learn_buckets.map do |bucket|
      { key: bucket, groups: ConceptGroup.grouped(ConceptBucket.vocabulary_for(bucket)) }
    end
    @ungenerated = ungenerated_concepts.size
    @recognition_guides = RecognitionGuide.indexed_for(current_user, recognition_group_keys)
    @ungenerated_guides = missing_recognition_guides.size
  end

  # GET /learn/:bucket/:concept
  def show
    @bucket    = validated_bucket
    @concept   = validated_concept(@bucket)
    @reference = current_user.concept_references.find_for(concept: @concept, language: @bucket)
    @ladder_targets = ladder_targets_for(@reference)
    @ladder_missing = @ladder_targets.any? && params[:ladder] == "missing"
    @lesson_missing = @reference.present? && !@reference.lesson? && params[:lesson] == "missing"
    @drills = ConceptDrills.for(current_user)
    @paused = current_user.concept_masteries.tier_paused.exists?(concept: @concept, language: @bucket)
  end

  AWAITING = { "guide" => :guide?, "ladder" => :complete?, "lesson" => :lesson? }.freeze
  AWAITING_REWRITE = %w[ladder lesson].freeze
  GENERATION_VERSION_FORMAT = /\A\d+\z/

  # GET /learn/:bucket/:concept/status
  def status
    bucket    = validated_bucket
    concept   = validated_concept(bucket)
    awaiting  = params.fetch(:awaiting, "guide").to_s
    predicate = AWAITING[awaiting]
    return head :bad_request if predicate.nil?
    return head :bad_request if AWAITING_REWRITE.include?(awaiting) && !params[:generation_version].to_s.match?(GENERATION_VERSION_FORMAT)

    reference = current_user.concept_references.find_for(concept:, language: bucket)
    body = { ready: reference&.public_send(predicate) || false }
    if AWAITING_REWRITE.include?(awaiting)
      body[:rewritten] = reference.present? && reference.generation_version > params[:generation_version].to_i
    end
    body.merge!(write_up_failure(concept, bucket)) unless body[:ready]

    render json: body
  end

  # POST /learn/:bucket/:concept/prepare
  def prepare_concept
    bucket  = validated_bucket
    concept = validated_concept(bucket)
    return head :forbidden unless writes_learn_content?

    ConceptReferenceFailures.clear(user_id: current_user.id, concept: concept, language: bucket)
    GenerateConceptReferenceJob.queue_rewrites(current_user, [ [ concept, bucket ] ], part: ladder_part)

    render json: { status: "queued" }
  end

  # POST /learn/prepare
  def prepare
    return redirect_to learn_path unless writes_learn_content?

    GenerateConceptReferenceJob.queue_missing(current_user, learn_pairs, priority: JobPriority::BACKGROUND)

    missing_recognition_guides.each do |group_key|
      bulk(GenerateRecognitionGuideJob).perform_later(group_key: group_key, user_id: current_user.id)
    end

    redirect_to learn_path, notice: t("learn.preparing")
  end

  # POST /learn/prepare_ladders
  def prepare_ladders
    gaps = writes_learn_content? ? LadderCoverage.for(current_user).gaps : []

    GenerateConceptReferenceJob.queue_rewrites(current_user, gaps, priority: JobPriority::BACKGROUND,
                                               part: GenerateConceptReferenceJob::LADDER_PART)

    redirect_to setup_path(anchor: "exercise-mix"), notice: t("exercise_mix.ladders_preparing", count: gaps.size)
  end

  private

  def writes_learn_content?
    return @writes_learn_content if defined?(@writes_learn_content)

    @writes_learn_content = current_user.writes_learn_content?
  end

  def bulk(job) = job.set(priority: JobPriority::BACKGROUND)

  def ladder_part = (GenerateConceptReferenceJob::LADDER_PART if params[:part] == GenerateConceptReferenceJob::LADDER_PART)

  def write_up_failure(concept, bucket)
    failure = ConceptReferenceFailures.read(user_id: current_user.id, concept: concept, language: bucket)
    return {} if failure.nil?

    text = ProviderFailureText.new(failure["kind"], provider: failure["provider"] || current_user.provider, surface: :reference,
                                   failed_at: Time.zone.parse(failure["at"].to_s), zone: current_user.effective_time_zone,
                                   retry_after: failure["retry_after"], variant: ProviderFailureText.variant_for(current_user))
    { failed: text.kind, message: text.brief }
  end

  def ladder_targets_for(reference)
    return [] unless writes_learn_content? && reference&.guide? && reference.ladder_addable?

    LadderCoverage.for(current_user).grounding_kinds(reference.concept, reference.language)
                  .map { |kind| t("sections.#{kind.key}.name") }
  end

  def references_by_key
    ConceptReference.indexed_for(current_user, language: learn_buckets)
  end

  def learn_pairs
    learn_buckets.flat_map { |bucket| ConceptBucket.vocabulary_for(bucket).map { |concept| [ concept, bucket ] } }
  end

  def ungenerated_concepts = ConceptReference.missing_for(current_user, learn_pairs)

  def recognition_group_keys
    @recognition_group_keys ||= learn_buckets.flat_map do |bucket|
      ConceptGroup.grouped(ConceptBucket.vocabulary_for(bucket)).map { |group, _concepts| RecognitionGuide.key_for(bucket, group) }
    end.compact.uniq
  end

  def missing_recognition_guides
    RecognitionGuide.missing_for(current_user, recognition_group_keys)
  end

  def encountered?(concept, bucket)
    current_user.concept_exposures.count(concept, bucket, on_or_before: Date.current).positive?
  end
end
