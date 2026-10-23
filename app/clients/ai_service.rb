require "json"

# Design notes: docs/code-notes/app/clients/ai_service.md
class AiService
  FINISHED_STATUSES = %w[completed incomplete].freeze

  RETRY_TIMEOUT_GUARD = lambda do |env, exception|
    return false if env.request.context.to_h[:single_attempt]
    return true unless exception.is_a?(Faraday::TimeoutError)

    !env.request.context.to_h[:long_running]
  end

  DIFFICULTY_ASSESSMENT_GRACE_SECONDS = 5

  MAX_GENERATED_CODE_LENGTH = 8_000

  Request = Data.define(:purpose, :system, :prompt, :history, :response_schema,
                        :max_tokens, :read_timeout, :cache_system, :single_attempt, :allow_truncated) do
    def self.build(system:, prompt:, purpose: nil, **settings)
      defaults = { history: [], response_schema: nil, max_tokens: nil, read_timeout: CallProfiles::READ_TIMEOUT,
                   cache_system: false, single_attempt: false, allow_truncated: false }
      new(purpose: purpose, system: system, prompt: prompt, **defaults.merge(settings))
    end

    def worst_case_seconds = CallProfiles.call_worst_case_seconds(read_timeout: read_timeout, single_attempt: single_attempt)
  end

  def self.judged_on?(date) = date.on_weekday?

  def self.request_for(purpose, system:, prompt:, history: [], response_schema: nil, blocking: false)
    profile  = CallProfiles.fetch(purpose)
    settings = profile.except(:blocking_read_timeout)
    if blocking
      settings[:read_timeout] = profile.fetch(:blocking_read_timeout) { raise ArgumentError, "#{purpose} has no blocking read timeout" }
    end
    Request.build(purpose: purpose, system: system, prompt: prompt, history: history, response_schema: response_schema, **settings)
  end

  MAX_LADDER_GUIDANCE_CHARS = 54_000

  MAX_CONCEPT_GUIDE_LENGTH = 4_000

  RAW_SNIPPET_LIMIT = 500

  attr_writer :house_key

  def house_key? = @house_key == true

  def initialize(api_key)
    @api_key = api_key
    @conn    = build_connection
  end

  def self.for(user)
    provider = AiProvider.find(user.provider)
    raise SetupError, "User #{user.id} has no recognized AI provider configured" unless provider
    unless provider.available?
      raise SetupError, "User #{user.id} has the test-only #{provider.provider_key} provider outside a local environment"
    end

    credential = ProviderCredential.for(user)
    provider.new(credential.key).tap { |service| service.house_key = credential.house }
  end

  def self.quota_day_zone = "UTC"

  def self.quota_day(now)
    start = now.in_time_zone(quota_day_zone).beginning_of_day
    start...start.tomorrow.beginning_of_day
  end

  def self.available? = true
  def self.key_pattern = nil
  def self.provider_key = nil

  def self.judges_review_prose? = false

  Price = Data.define(:input, :output, :cache_write, :cache_read, :checked_on)
  PRICE_PER_MILLION = {}.freeze
  PRICED_TOKENS = { input: :input_tokens, output: :output_tokens,
                    cache_write: :cache_write_tokens, cache_read: :cache_read_tokens }.freeze

  def self.price_for(model) = self::PRICE_PER_MILLION[model]

  def self.cost_usd(result)
    counts = PRICED_TOKENS.transform_values { |key| result[key].to_i }
    return BigDecimal(0) if counts.values.all?(&:zero?)

    price = price_for(result[:model]) or return
    counts.sum { |rate, count| count * BigDecimal(price.public_send(rate).to_s) } / 1_000_000
  end

  JudgedSet = Data.define(:problem_set, :dropped_sections, :outcomes, :plan_notes, :solves) do
    def initialize(solves: [], **) = super
  end

  def model_for(purpose) = routed_model(purpose)

  def generate_exercise(user, language: user.language_for_today, blocking: false)
    generate_unjudged_exercise(user, language: language, blocking: blocking).problem_set
  end

  def generate_unjudged_exercise(user, language: user.language_for_today, blocking: false, deadline: GenerationDeadline::NONE)
    draft   = draft_exercise(user, language: language, blocking: blocking, deadline: deadline)
    planned = draft.kinds.map(&:key)
    dropped = draft.unusable_sections.select { |section| planned.include?(section.key) }
    ExerciseDraft.finish(draft, draft.problem_set, provider: exercise_draft_provider,
                                                   dropped_concepts: dropped.to_h { |section| [ section.key, section.concept ] })
    JudgedSet.new(problem_set: draft.problem_set, dropped_sections: dropped.map(&:key), outcomes: {},
                  plan_notes: draft.plan.notes, solves: [])
  end

  def generate_judged_exercise(user, language: user.language_for_today, deadline: GenerationDeadline::NONE)
    draft = draft_exercise(user, language: language, blocking: false, deadline: deadline)
    JudgedGeneration.call(
      user: user, draft: draft,
      providers: -> { fresh_service.judged_generation_provider(deadline) },
      finish: ->(set, **logs) { ExerciseDraft.finish(draft, set, provider: exercise_draft_provider, **logs) }
    )
  end

  def review_sections(user, exercise, daily_response, sections:)
    ReviewGrading.call(
      user: user, exercise: exercise, response: daily_response, sections: sections,
      coach: LanguagePrompts.for(exercise.language)[:coach], providers: -> { fresh_service.review_grading_provider }
    )
  end

  def review_grading_provider
    ReviewGrading::Provider.new(
      grade: method(:grade_review), judge_prose: method(:judge_review_prose), assess_difficulty: method(:assess_difficulty),
      translate: method(:translate_pseudocode), day_context: method(:build_review_day_context),
      provider_key: self.class.provider_key, judges_prose: self.class.judges_review_prose?
    )
  end

  def generate_concept_reference(user, concept, language)
    config = LanguagePrompts.for(language)

    result = call_and_log(user, AiService.request_for("generate_concept_reference",
      **ConceptReferencePrompt.generate(concept: concept, language: language, coach: config[:coach], label: config[:label])))

    reference = parse_json_object(result[:text], subject: "concept reference")

    missing = ConceptReference::REFERENCE_FIELDS.reject { |field| reference[field].is_a?(String) && reference[field].strip.present? }
    if missing.any?
      raise ProviderError::InvalidResponseError, "Concept reference missing required field(s): #{missing.join(', ')}"
    end

    normalize_optional_reference_fields!(reference)

    reference
  end

  def generate_recognition_guide(user, group_key)
    result = call_and_log(user, AiService.request_for("generate_recognition_guide",
      **RecognitionGuidePrompt.generate(group_key: group_key, subject: recognition_subject(group_key))))

    guide = parse_json_object(result[:text], subject: "recognition guide")
    RecognitionGuide::FIELDS.each { |field| guide[field] = usable_optional_text(guide[field], MAX_CONCEPT_GUIDE_LENGTH) }

    missing = RecognitionGuide::FIELDS.select { |field| guide[field].nil? }
    raise ProviderError::InvalidResponseError, "Recognition guide missing usable field(s): #{missing.join(', ')}" if missing.any?

    guide.slice(*RecognitionGuide::FIELDS)
  end

  def explain_concept_differently(user, reference, prior_alternates: [])
    already_read = ConceptReference::REFERENCE_FIELDS.index_with { |field| reference.public_send(field) }

    result = call_and_log(user, AiService.request_for("explain_concept_differently",
      **ConceptReferencePrompt.reframe(concept: reference.concept, coach: LanguagePrompts.for(reference.language)[:coach],
                                       already_read: already_read, prior_alternates: prior_alternates)))

    text_or_raise(result, subject: "alternate concept explanation")
  end

  def explain_differently(user, exercise, daily_response, section:, prior_alternates: [])
    review = daily_response.ai_review&.dig(section) || {}

    result = call_and_log(user, AiService.request_for("explain_differently",
      **ExplainDifferentlyPrompt.generate(
        coach: LanguagePrompts.for(exercise.language)[:coach], question: exercise.problem_set.dig(section, "question"),
        answer: daily_response.answer_for(section), missed: DailyResponse.review_points(review["missed"]),
        prior_alternates: prior_alternates
      )))

    text_or_raise(result, subject: "alternate explanation")
  end

  def answer_follow_up(user, exercise, daily_response, section:, question:, thread: [])
    result = call_and_log(user, AiService.request_for("review_follow_up",
      **FollowUpPrompt.generate(
        coach: LanguagePrompts.for(exercise.language)[:coach], exercise_question: exercise.problem_set.dig(section, "question"),
        review: daily_response.ai_review&.dig(section) || {}, answer: daily_response.answer_for(section),
        question: question, thread: thread
      )))

    text_or_raise(result, subject: "follow-up answer")
  end

  def duck_response(user, exercise, section:, message:, thread: [])
    result = call_and_log(user, AiService.request_for("duck_thread",
      **DuckPrompt.generate(section_data: exercise.problem_set[section.to_s], message: message, thread: thread)))

    text = text_or_raise(result, subject: "duck response")
    result[:truncated] ? "#{text}…" : text
  end

  def critique_pseudocode(user, exercise, section:, pseudocode:)
    prompt = PseudocodePrompt.critique(problem_statement: problem_statement(exercise, section), pseudocode: pseudocode)
    result = call_and_log(user, AiService.request_for("pseudocode_critique", **prompt))

    parsed     = parse_json_object(result[:text], subject: "pseudocode critique", log_raw: false)
    gaps_found = parsed["gaps_found"]
    unless [ true, false ].include?(gaps_found)
      raise ProviderError::InvalidResponseError, "Pseudocode critique returned no usable \"gaps_found\" flag"
    end

    gaps = ExerciseSection::PseudocodeToCode.normalize_critique(parsed["gaps"])
    raise ProviderError::InvalidResponseError, "Pseudocode critique claimed gaps but returned none usable" if gaps_found && gaps.empty?

    log_pseudocode_critique(user, gaps_found, gaps)
    { gaps_found: gaps_found, gaps: gaps_found ? gaps : [] }
  end

  def translate_pseudocode(user, exercise, section:, pseudocode:)
    prompt = PseudocodePrompt.translate(problem_statement: problem_statement(exercise, section), pseudocode: pseudocode,
                                        language_label: LanguagePrompts.for(exercise.language)[:label])
    result = call_and_log(user, AiService.request_for("pseudocode_translate", **prompt))

    code = UserText.normalize(text_or_raise(result, subject: "pseudocode translation"))
    if code.length > MAX_GENERATED_CODE_LENGTH
      raise ProviderError::InvalidResponseError,
            "Pseudocode translation came back too long to be usable (#{code.length} characters)"
    end

    code
  end

  def judge_section(user, kind, section, rung:, locked:, deadline: GenerationDeadline::NONE)
    request = AiService.request_for("judge_section", **SectionJudgePrompt.generate(kind: kind, section: section, rung: rung, locked: locked))
    result = call_and_log(user, request, deadline: deadline)
    raw = parse_json_object(result[:text], subject: "#{kind.key} verdict", log_raw: kind.judge_solve_options.nil?)
    JudgeVerdict.parse(raw, kind: kind)
  end

  def judge_review_prose(user, kind, review, coach:)
    projection = ReviewProseVerdict.project(review)
    result = call_and_log(user, AiService.request_for("judge_review",
      **ReviewProseJudgePrompt.generate(kind: kind, coach: coach, projection: projection)))
    raw = parse_json_object(result[:text], subject: "review prose verdict", log_raw: false)
    ReviewProseVerdict.parse(raw, projection: projection)
  end

  def self.error_code_for(error) = error.is_a?(ProviderError) ? error.class.error_code : ProviderError.error_code

  def self.failure_code_for(error) = error.is_a?(ProviderError) ? error.class.failure_code : ProviderError.failure_code

  def self.judge_fallback_reason(error)
    case error
    when JudgeVerdict::Invalid, ReviewProseVerdict::Invalid then "invalid_output"
    when Timeout::Error                                     then ProviderError::TimeoutError.judge_fallback_reason
    when ProviderError then error.class.judge_fallback_reason || http_status_code_for(error) || error_code_for(error)
    else                                                         error_code_for(error)
    end
  end

  def self.http_status_code_for(error)
    "http_#{error.http_status}" if error.instance_of?(ProviderError) && error.http_status
  end

  protected

  def judged_generation_provider(deadline = GenerationDeadline::NONE)
    JudgedGeneration::Provider.new(
      judge_section: ->(*args, **options) { judge_section(*args, **options, deadline: deadline) },
      retry_section: ->(draft, kind, concept) { retry_section(draft, kind, concept, deadline: deadline) },
      judge_identity: { judge_provider: self.class.provider_key, judge_model: model_for("judge_section") }
    )
  end

  private

  def draft_exercise(user, language:, blocking:, deadline: GenerationDeadline::NONE)
    ExerciseDraft.call(user, language: language, blocking: blocking, deadline: deadline, provider: exercise_draft_provider)
  end

  def retry_section(draft, kind, concept, deadline: GenerationDeadline::NONE)
    ExerciseDraft.retry_section(draft, kind, concept, deadline: deadline, provider: exercise_draft_provider)
  end

  def exercise_draft_provider
    ExerciseDraft::Provider.new(
      prompt: ->(*args, **options) { generation_prompt(*args, **options) },
      generate: ->(*args, **options) { generate_problem_set(*args, **options) },
      record_suggestion: ->(suggestion) { record_suggested_concept(suggestion) }
    )
  end

  def record_suggested_concept(suggestion) = SuggestedConcept.record!(language: suggestion.bucket, name: suggestion.name)

  def generate_problem_set(user, purpose, language, prompt, subject:, blocking: false, deadline: GenerationDeadline::NONE)
    request = AiService.request_for(purpose, blocking: blocking, system: build_system_prompt(language), prompt: prompt)
    parse_json_object(call_and_log(user, request, deadline: deadline)[:text], subject: subject, log_raw: false)
  end

  def generation_prompt(user, language, plan:, history:, difficulty:, ladders:)
    GenerationPrompt.new(user, language, plan: plan, history: history, difficulty: difficulty, ladders: ladders,
                         retention_annotation: method(:annotate_retention_concept))
  end

  def normalize_optional_reference_fields!(reference)
    ConceptReference::GUIDE_FIELDS.each { |field| reference[field] = usable_optional_text(reference[field], MAX_CONCEPT_GUIDE_LENGTH) }
    ConceptReference::LADDER_FIELDS.each { |field| reference[field] = usable_optional_text(reference[field], ConceptReference::MAX_LADDER_RUNG_LENGTH) }
    reference["lesson"] = ConceptLesson.from_provider(reference["lesson"])
  end

  def usable_optional_text(value, max_length)
    text = value.is_a?(String) ? value.strip : nil

    text.blank? || text.length > max_length ? nil : text
  end

  def flatten_history(history, prompt)
    return prompt if history.empty?

    "Conversation so far:\n#{render_thread(history)}\n\n#{prompt}"
  end

  def render_thread(thread)
    thread.map { |turn| "#{turn[:role] == "assistant" ? "You" : "Them"}: #{turn[:content]}" }.join("\n")
  end

  def problem_statement(exercise, section) = exercise.problem_set.dig(section.to_s, "problem_statement")

  def log_pseudocode_critique(user, gaps_found, gaps)
    Rails.logger.info(
      "[pseudocode] user=#{user.id} date=#{Date.current} phase=critique " \
      "gaps_found=#{gaps_found} gaps=#{gaps.size}"
    )
  end

  def text_or_raise(result, subject:)
    text = result[:text].to_s.strip
    raise ProviderError::InvalidResponseError, "Provider returned an empty #{subject}" if text.blank?
    text
  end

  def error_code_for(error) = self.class.error_code_for(error)

  def annotate_retention_concept(cm, kinds, language, code_review_mode, rungs)
    hosts = kinds.filter_map do |kind|
      mode = code_review_mode if kind == ExerciseSection::CodeReview
      kind.key if can_host?(cm, kind.key, language, mode: mode, rung: rungs[kind])
    end

    return nil if hosts.empty?

    "#{cm.concept} (#{hosts.to_sentence(two_words_connector: ' or ', last_word_connector: ', or ')})"
  end

  def can_host?(cm, section_key, language, mode: nil, rung: nil)
    ConceptVocabulary.selectable_for_section(section_key, language, mode: mode, rung: rung).include?(cm.concept)
  end

  def call(request)
    resp = post(request_body(request), request)
    raise_for_status(resp) unless resp.success?
    read_result(parse_provider_envelope(resp.body, provider: provider_name), request).merge(http_status: resp.status)
  rescue Faraday::Error => e
    raise (e.is_a?(Faraday::TimeoutError) ? ProviderError::TimeoutError : ProviderError::NetworkError), "Network error calling #{provider_name}: #{e.message}"
  end

  def post(body, request)
    @conn.post(self.class::API_URL, body.to_json) do |req|
      req.options.timeout = request.read_timeout
      req.options.context = (req.options.context || {}).merge(long_running: long_running?(request), single_attempt: request.single_attempt)
    end
  end

  def long_running?(request) = request.read_timeout > CallProfiles::READ_TIMEOUT

  # Subclasses supply API_URL and the hooks below; read_result returns text, token and cache counts, model, truncated and refusal.
  def request_body(_request)
    raise NotImplementedError, "#{self.class} must implement #request_body"
  end

  def read_result(_parsed, _request)
    raise NotImplementedError, "#{self.class} must implement #read_result"
  end

  def provider_name
    raise NotImplementedError, "#{self.class} must implement #provider_name"
  end

  def raise_for_status(_resp)
    raise NotImplementedError, "#{self.class} must implement #raise_for_status"
  end

  # Subclasses must implement: returns a configured Faraday::Connection.
  def build_connection
    raise NotImplementedError, "#{self.class} must implement #build_connection"
  end

  def build_system_prompt(language = "ruby_rails") = GenerationPrompt.system_prompt(**LanguagePrompts.for(language).slice(:coach, :focus))

  def build_review_day_context(coach, exercise, daily_response)
    ratings  = daily_response.section_ratings
    sections = exercise.active_section_keys.map do |key|
      { key: key, section: (exercise.problem_set[key] || {}).merge("rounds" => daily_response.pseudocode_round(key)),
        answer: daily_response.answer_for(key), rating: ratings[key] }
    end

    ReviewPrompt.day_system(coach: coach, sections: sections)
  end

  def build_review_section_prompt(exercise, daily_response, section)
    ReviewPrompt.section_prompt(key: section, section: exercise.problem_set[section] || {},
                                answer: daily_response.answer_for(section), rung: review_rung(exercise, daily_response, section))
  end

  def review_rung(exercise, daily_response, section)
    stamped = exercise.problem_set.dig(section, "pitched_at")
    KindDifficulty::LEVELS.include?(stamped) ? stamped : current_rung(daily_response.user, section)
  end

  def current_rung(user, section)
    difficulty = user ? KindDifficulty.for(user) : KindDifficulty.none
    difficulty.rung_for(ExerciseSection.for(section), skill_level: user&.skill_level)
  end

  INFRASTRUCTURE_ERRORS = [
    ActiveRecord::ConnectionNotEstablished,
    Timeout::Error,
    IOError
  ].freeze

  def grade_review(user, exercise, daily_response, section, context)
    result = call_and_log(user, AiService.request_for("review_response",
      system: context, prompt: build_review_section_prompt(exercise, daily_response, section)
    ))
    parse_json_object(result[:text], subject: "#{section} review", log_raw: false)
      .except(ReviewProseVerdict::ORIGINAL_KEY, "rubric").merge("rubric" => ReviewedSectionResults::RUBRIC_VERSION)
  end

  def assess_difficulty(user, exercise, sections:)
    result = call_and_log(user, AiService.request_for("assess_difficulty",
      **DifficultyPrompt.generate(coach: LanguagePrompts.for(exercise.language)[:coach],
                                  sections: sections.to_h { |section| [ section, exercise.problem_set[section.to_s] ] })))

    assessed = parse_json_object(result[:text], subject: "difficulty assessment")
    sections.to_h { |section| [ section, DailyResponse.usable_difficulty(assessed[section]) ] }.compact
  end

  def recognition_subject(group_key)
    RecognitionGuide::NAMED_GROUP_SUBJECTS.fetch(group_key) { LanguagePrompts::ALL.fetch(group_key).fetch(:focus) }
  end

  # A non-Hash must fail here: an array saved to ai_review is truthy, flips #reviewed? and strands an empty review.
  def parse_json_object(text, subject:, log_raw: true)
    parsed = parse_json_response(text, subject: subject, log_raw: log_raw)
    return parsed if parsed.is_a?(Hash)

    raise ProviderError::InvalidResponseError, "Provider returned #{parsed.class} instead of a JSON object for the #{subject}"
  end

  def parse_json_response(text, subject: "response", log_raw: true)
    clean = text.to_s.gsub(/\A```(?:json)?\n?/, "").gsub(/\n?```\z/, "").strip
    JSON.parse(clean)
  rescue JSON::ParserError => e
    raise ProviderError::InvalidResponseError, "Provider returned invalid JSON for the #{subject}" unless log_raw

    log_raw_snippet("Invalid JSON from provider", text)
    raise ProviderError::InvalidResponseError, "Provider returned invalid JSON: #{e.message}"
  end

  def parse_provider_envelope(body, provider:)
    parsed = JSON.parse(body.to_s)
    return parsed if parsed.is_a?(Hash)

    unreadable_envelope!(body, provider)
  rescue JSON::ParserError
    unreadable_envelope!(body, provider)
  end

  def unreadable_envelope!(body, provider)
    text = body.to_s
    if text.lstrip.start_with?("{", "[", '"')
      Rails.logger.error("Unreadable #{provider} response body: #{text.bytesize} bytes of cut-off JSON, withheld")
    else
      log_raw_snippet("Unreadable #{provider} response body", text)
    end
    raise ProviderError::InvalidResponseError, "#{provider} returned an unreadable response"
  end

  def extract_provider_message(body, fallback:)
    parsed  = JSON.parse(body.to_s)
    message = parsed.is_a?(Hash) ? parsed.dig("error", "message") : nil
    message.presence || fallback
  rescue JSON::ParserError
    fallback
  end

  def raise_if_key_rejected(company, status)
    return unless [ 401, 403 ].include?(status)

    Rails.logger.error("#{company} authentication failed (HTTP #{status})")
    raise ProviderError::AuthenticationError.new("#{company} rejected your API key or its permissions. Check it in Settings.",
                                                 http_status: status)
  end

  def log_raw_snippet(label, content)
    text = content.to_s
    snippet = text.byteslice(0, RAW_SNIPPET_LIMIT).scrub
    snippet += "... (truncated, #{text.bytesize} bytes total)" if text.bytesize > RAW_SNIPPET_LIMIT
    Rails.logger.error("#{label}: #{snippet}")
  end

  def fresh_service
    self.class.new(@api_key).tap { |service| service.house_key = house_key? }
  end

  def log_usage(user, result, purpose:)
    ActiveRecord::Base.connection_pool.with_connection do
      ApiUsage.create!(
        user:       user,
        house_key:  house_key?,
        tokens_in:  result[:input_tokens].to_i,
        tokens_out: result[:output_tokens].to_i,
        model:      result[:model],
        provider:   self.class.provider_key,
        cache_read_tokens:  result[:cache_read_tokens],
        cache_write_tokens: result[:cache_write_tokens],
        http_status: result[:http_status],
        failure:     result[:failure],
        quota_id:    result[:quota_id],
        cost_usd:    usage_cost(result),
        purpose:    purpose,
        date:       Date.current
      )
    end
  rescue ActiveRecord::ActiveRecordError => e
    Rails.logger.warn(
      "[usage] ApiUsage log failed for purpose=#{purpose} user_id=#{user&.id} " \
      "tokens_in=#{result[:input_tokens].to_i} tokens_out=#{result[:output_tokens].to_i}: " \
      "#{e.class}: #{e.message}"
    )
  end

  def usage_cost(result)
    self.class.cost_usd(result).tap do |cost|
      Rails.logger.warn("[usage] #{self.class} has no price for model=#{result[:model].inspect}; cost_usd left null") if cost.nil?
    end
  end

  def call_and_log(user, request, deadline: GenerationDeadline::NONE)
    deadline.ensure_fits!(request)
    TrialAllowance.check!(user, provider: self.class) if house_key?
    begin
      result = call(request)
    rescue ProviderError => e
      e.provider ||= self.class.provider_key
      log_usage(user, failed_call_result(e, request.purpose), purpose: request.purpose)
      raise
    end
    log_usage(user, result.merge(failure: reply_failure_code(result, request.allow_truncated)), purpose: request.purpose)
    raise_for_reply!(result, request.allow_truncated)
    result
  end

  def raise_for_reply!(result, allow_truncated)
    raise tagged(ProviderError.new(result[:error])) if result[:error]
    raise tagged(ProviderError::RefusalError.new("The provider declined this request (#{result[:refusal]})")) if result[:refusal]
    return unless result[:truncated] && !allow_truncated

    raise tagged(ProviderError::TruncatedResponseError.new("Provider did not finish its reply " \
                                                           "(#{result[:output_tokens].to_i} output tokens, thinking included)"))
  end

  def tagged(error) = error.tap { |e| e.provider = self.class.provider_key }

  def unfinished_reply(usage, status)
    Rails.logger.warn("#{provider_name} reply did not finish (status=#{status.inspect})")
    usage.merge(error: "#{provider_name} did not complete its response. Try again.")
  end

  def failed_call_result(error, purpose)
    { input_tokens: 0, output_tokens: 0, model: routed_model(purpose),
      http_status: error.http_status, failure: self.class.failure_code_for(error), quota_id: error.quota_id }
  end

  def reply_failure_code(result, allow_truncated)
    return "provider_error" if result[:error]
    return "refusal" if result[:refusal]
    return "truncated" if result[:truncated] && !allow_truncated

    nil
  end

  def routed_model(_purpose) = nil

  def parse_error_body(body)
    parsed = JSON.parse(body.to_s)
    parsed.is_a?(Hash) ? parsed : {}
  rescue JSON::ParserError
    {}
  end

  def error_envelope(body)
    error = parse_error_body(body)["error"]
    error.is_a?(Hash) ? error : {}
  end

  def self.daily_quota_reset_at(failed_at)
    failed_at + 1.day
  end

  def retry_after_seconds(resp)
    value = resp.headers["retry-after"].to_s
    value.match?(/\A\d+\z/) ? value.to_i : nil
  end
end
