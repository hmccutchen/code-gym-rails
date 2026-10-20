require "json"

# Design notes: docs/code-notes/app/services/ai_service.md
class AiService
  FINISHED_STATUSES = %w[completed incomplete].freeze
  OPEN_TIMEOUT = 10
  READ_TIMEOUT = 45

  GENERATION_READ_TIMEOUT      = 300
  SYNC_GENERATION_READ_TIMEOUT = 90
  RETRY_READ_TIMEOUT           = SYNC_GENERATION_READ_TIMEOUT

  CONCEPT_REFERENCE_READ_TIMEOUT = SYNC_GENERATION_READ_TIMEOUT

  REVIEW_READ_TIMEOUT = 120

  REVIEW_JUDGE_READ_TIMEOUT = 30

  RETRY_MAX          = 2
  RETRY_MAX_INTERVAL = 8

  def self.call_budget_seconds(read_timeout)
    (read_timeout * (RETRY_MAX + 1)) + (RETRY_MAX * RETRY_MAX_INTERVAL)
  end

  def self.worst_case_call_seconds(read_timeout)
    call_budget_seconds(read_timeout) + ((RETRY_MAX + 1) * OPEN_TIMEOUT)
  end

  def self.single_attempt_call_seconds(read_timeout)
    OPEN_TIMEOUT + read_timeout
  end

  def self.call_worst_case_seconds(read_timeout:, single_attempt:)
    single_attempt ? single_attempt_call_seconds(read_timeout) : worst_case_call_seconds(read_timeout)
  end

  RETRY_TIMEOUT_GUARD = lambda do |env, exception|
    return false if env.request.context.to_h[:single_attempt]
    return true unless exception.is_a?(Faraday::TimeoutError)

    !env.request.context.to_h[:long_running]
  end

  DUCK_RESPONSE_MAX_TOKENS = 400

  CONCEPT_ALTERNATE_MAX_TOKENS = 500

  DUCK_EXPLAIN_REQUEST = "Explain what this exercise is asking, in plain language."

  PSEUDOCODE_CRITIQUE_JSON_OVERHEAD_TOKENS = 100
  PSEUDOCODE_CRITIQUE_MAX_TOKENS =
    (ExerciseSection::PseudocodeToCode::MAX_CRITIQUE_POINTS *
      ExerciseSection::PseudocodeToCode::MAX_CRITIQUE_POINT_LENGTH / 3) +
    PSEUDOCODE_CRITIQUE_JSON_OVERHEAD_TOKENS

  DIFFICULTY_ASSESSMENT_JSON_OVERHEAD_TOKENS = 150
  DIFFICULTY_ASSESSMENT_CHARS_PER_TOKEN = 2.5
  DIFFICULTY_ASSESSMENT_OVERRUN_HEADROOM = 2
  DIFFICULTY_ASSESSMENT_MAX_TOKENS =
    ((ExerciseSection::MAX_SECTIONS *
      (DailyResponse::MAX_DIFFICULTY_REASON_LENGTH / DIFFICULTY_ASSESSMENT_CHARS_PER_TOKEN) *
      DIFFICULTY_ASSESSMENT_OVERRUN_HEADROOM) +
      DIFFICULTY_ASSESSMENT_JSON_OVERHEAD_TOKENS).ceil

  DIFFICULTY_ASSESSMENT_GRACE_SECONDS = 5

  MAX_GENERATED_CODE_LENGTH = 8_000

  def self.explain_differently_standard(subject)
    "Explain the SAME #{subject} again using a genuinely different approach — a\n" \
      "different analogy, a different level of abstraction, or a concrete worked\n" \
      "scenario instead of a principle. Do not repeat the original wording."
  end

  PLAIN_LANGUAGE_STANDARD = <<~STANDARD.chomp.freeze
    Write prose for the engineer this way:

    Avoid, in order of how often these actually show up:
    - Manufactured rhetorical contrast — "not X, but Y" used purely for punch when a plain sentence says the same thing.
    - Buzzwords and jargon. Use the plain-language equivalent; if a technical term is genuinely necessary, define it briefly on first use.
    - Placeholder phrases — "please note," "at this time," "it's worth mentioning."
    - Overusing "please" in instructions — state it directly.
    - Starting every sentence with the same construction.
    - Exclamation points, outside genuine, rare emphasis.
    - Forced cleverness or trying to sound entertaining.
    - Both choppy fragments and long-winded run-ons.

    Aim for:
    - Active voice — make clear who or what is doing the thing.
    - Second person, direct address.
    - Concrete over abstract — a specific example beats a general description of the same idea.
    - Conditions before instructions, not after.
    - Natural rhythm — if a sentence sounds stilted read aloud, rewrite it.

    Calibration: too informal ("This is a total game-changer!") and too formal/overwrought ("The interface undergoes a paradigmatic transformation") are both wrong; aim for the plain middle ("This changes how the interface works").
  STANDARD

  RATING_RUBRIC = <<~RUBRIC.chomp.freeze
    How to choose "rating": rate the answer against the level its section was pitched at, which the grading instruction states on its "Pitched at" line, so a rating means the same thing at every level. Base it on the gaps you list in "missed". A gap is essential when, left as the engineer wrote it, the code or decision would behave wrongly or a requirement the problem states would go unmet. Missing syntax, polish or wording, or a step any engineer at this level would take for granted, is not essential and does not lower the rating. Judge what is essential against the problem as written: a problem simpler than its level's description is graded on what it actually asks. Each section's grading note says what its main point and its essential pieces are.
    - "beginner": missed the main point of the section.
    - "developing": found the main point, but missed or misexplained at least one essential piece.
    - "solid": no essential misses.
    - "strong": solid, plus something the question did not ask for that matters here, such as a tradeoff or a consequence.
    The rating must agree with "missed": when "missed" names an essential gap, the rating is not "solid" or "strong". When a section's grading note says its rating is already fixed, that note wins.
  RUBRIC

  RUBRIC_VERSION = 1

  PSEUDOCODE_CRITIQUE_SYSTEM_PROMPT = <<~PROMPT.chomp
    You are reviewing an engineer's PSEUDOCODE plan before any code exists. They
    have not submitted or been graded. Your job is to point out genuine gaps in
    the plan's reasoning, and nothing else.

    #{ExerciseSection::PseudocodeToCode.gap_standard}

    Never write code, never show a corrected plan, and never restate their plan
    back to them. Name what breaks and why, in one or two sentences per point.

    If the plan holds up, say so by returning "gaps_found": false with an empty
    "gaps" array. Do NOT invent a point to seem useful — an empty result is a
    valid and expected outcome.

    Return a single JSON object:
    {"gaps_found": true|false, "gaps": ["string", "..."]}
    At most #{ExerciseSection::PseudocodeToCode::MAX_CRITIQUE_POINTS} entries in "gaps".
    "gaps" must be empty when "gaps_found" is false, and non-empty when it is true.
  PROMPT

  PSEUDOCODE_TRANSLATE_SYSTEM_PROMPT = <<~PROMPT.chomp
    You translate an engineer's pseudocode into real code. You are a
    TRANSCRIBER, not a reviewer and not an assistant. You do not improve
    anything.

    - If the pseudocode omits an edge case, the code omits it too. Do not add a
      guard, a nil check, a bounds check, or a default the pseudocode did not state.
    - If the pseudocode is ambiguous, pick the MOST LITERAL reading and implement
      that. Do not pick the reading that would work better.
    - If the pseudocode is wrong, implement the wrong thing. Do not fix it.
    - Do not add error handling, logging, validation, or defensive checks.
    - Do not add comments. In particular, never add a comment pointing out a
      problem ("# note: this will fail on empty input"). Naming the flaw is
      someone else's job, not yours.
    - Do not rename, reorder, or restructure for clarity.
    - Add ONLY what is required to make the result syntactically valid:
      declarations, signatures, brackets, imports.

    Return the code and nothing else — no prose, no explanation, no fences.
  PROMPT

  DUCK_SYSTEM_PROMPT = <<~PROMPT.chomp
    You are a Socratic thinking partner helping an engineer work through a
    problem they have NOT yet submitted or been graded on.

    Every message they send is one of two kinds. Decide which before replying.

    1. UNDERSTANDING THE PROBLEM — they are asking what the exercise means, what
       a term or a piece of the snippet does, or for a plainer restatement of the
       question. Examples: "what is this even asking?", "what does memoization
       mean?", "explain this scenario simply", "what does this line do?"
       Answer these DIRECTLY, with one concrete everyday analogy if it helps.
       Describe only what is already on their
       screen — the situation as written, the vocabulary, the shape of the
       question. Explaining what a problem IS is always allowed.

    2. SOLVING THE PROBLEM — they are asking for the fix, the answer, corrected
       code, which option to pick, or what is wrong with the snippet. Examples:
       "what's the bug?", "how do I fix this?", "which option is right?", "just
       tell me the answer", "is my approach correct?"
       Never comply. Never state the correct answer, the specific fix, or write
       corrected or complete code — not even as an illustrative example. Respond
       with a single guiding question that helps them find it themselves.

    When a message mixes both ("what does this method do, and what's wrong with
    it?"), explain the first part and answer the second with a guiding question.
    When you genuinely cannot tell which kind it is, treat it as kind 2.

    Keep it short: 1-3 sentences for a guiding question, up to 4 for an
    explanation. No preamble.

    #{PLAIN_LANGUAGE_STANDARD}
  PROMPT

  JUDGE_MAX_TOKENS = 1_200

  JUDGE_PRINCIPLE_GUIDANCE = {
    "scope_mismatch" => "answering correctly does not require the tagged concept, or the question asks for something the concept does not cover.",
    "unstated_prerequisite" => "solving depends on important knowledge that is neither the tagged concept nor supplied by the problem, and a brief clarifying phrase could not reasonably supply it.",
    "underdetermined" => "information needed for a defensible answer is missing and is not present or implied anywhere in the draft.",
    "reasoning_failure" => "measured against the kind's task, the wording structurally gives away the defect's location or the solution, or otherwise makes the task impossible as designed. Structural only: a removable leaking sentence is an edit."
  }.freeze

  JUDGE_PRINCIPLE_LINES = JudgeVerdict::PRINCIPLES
    .map { |principle| "- #{principle}: #{JUDGE_PRINCIPLE_GUIDANCE.fetch(principle)}" }
    .join("\n").freeze

  JUDGE_SYSTEM_PROMPT = <<~PROMPT.freeze
    You are checking one section of a generated coding exercise before an engineer sees it. You judge the section as written; you are not told what its author intended.

    A question may be difficult, unfamiliar, or conceptually demanding. Its difficulty must come from the intended reasoning task, not from unclear wording, missing information, or accidental prerequisites. Reject when the problem itself is broken. Edit when the problem is sound but poorly expressed. Never reject a problem for being hard.

    Work through these checks internally, in this order, and stop at the first rejection. Reply with only the JSON verdict, with no text before or after it.
    1. Answerable. Can a knowledgeable developer at the stated level reach a defensible answer without guessing which scenario the author meant? Normal technical inference is allowed. The section is unanswerable only when materially different readings are possible and the answer depends on picking the author's. If prose can close the gap, that is an edit, on one condition: a clarification may only surface what the draft already shows or implies, such as behaviour visible in the code that the prose never states. If the missing information is not in the draft at all, you have no source for it: reject as underdetermined. Never invent facts.
    2. Valid. Check the remaining rejection principles.
    3. Improvable. If the section is sound, rewrite its prose fields where one of the listed issues applies, or return keep.

    Rejection principles, the only #{JudgeVerdict::PRINCIPLES.size}:
    #{JUDGE_PRINCIPLE_LINES}

    Never reject because a section is straightforward, familiar, hard, unfamiliar, or names its concept. The tagged concept may be new to the engineer; a reference explains it beside the section, so unfamiliarity with it is never grounds for rejection. Judge against the stated level, not any notion of a typical engineer: a section at principal level is supposed to be difficult. You never change difficulty: the draft already pitched this section, and you preserve that pitch and the task exactly.

    Leakage means revealing where the defect is or what the answer is. It does not mean naming the domain or the tagged concept. "What vulnerability exists in this endpoint?" is the intended framing for a security review, not leakage.

    Edits rewrite prose fields only. The teaching note is a hint the engineer can reveal after attempting, so it gets the same prose rules and must not alter the task. Issues, the only #{JudgeVerdict::ISSUE_TYPES.size}: #{JudgeVerdict::ISSUE_TYPES.join(", ")}.

    When you edit: never modify code or schema content, the tagged concept, the kind, or any field that carries the planted defect. Never change the task or the difficulty; never make a subtle flaw more obvious or an obvious one more obscure. Never add a technical claim the draft does not make or imply. Never add information only to make the answer easier to find, and never solve the exercise. Never remove or genericize the scenario setting; trim filler inside a statement, never the setting. Return exactly the fields you were asked to rewrite, nothing else.

    For any prose you rewrite:
    #{PLAIN_LANGUAGE_STANDARD}

    Return only JSON, one of:
    {"status":"keep"}
    {"status":"edit","issues":[{"type":"...","evidence":"<quoted text>"}],"fields":{"<prose field>":"<rewritten>"}}
    {"status":"reject","principle":"...","evidence":"<quoted text>","reason":"<one or two sentences>"}
  PROMPT

  REVIEW_JUDGE_MEASURED_MAX_OUTPUT_TOKENS = 371

  REVIEW_JUDGE_MAX_TOKENS = 1_500

  REVIEW_PROSE_ISSUE_GUIDANCE = {
    "plain_language_violation" => "jargon or buzzwords where a plainer word works, filler such as \"basically\" or \"at the end of the day\", or a miss explained in a more complicated way than it needs.",
    "verbosity" => "the same point made twice, the rating restated in prose, or filler."
  }.freeze

  REVIEW_PROSE_ISSUE_LINES = ReviewProseVerdict::ISSUE_TYPES
    .map { |type| "- #{type}: #{REVIEW_PROSE_ISSUE_GUIDANCE.fetch(type)}" }
    .join("\n").freeze

  REVIEW_PROSE_JUDGE_SYSTEM_PROMPT = <<~PROMPT.freeze
    You are editing the prose of one section's code review so the engineer who submitted the work can read it easily. The grade is final: you change how the review says things, never what it says.

    Check for these problems, the only #{ReviewProseVerdict::ISSUE_TYPES.size}:
    #{REVIEW_PROSE_ISSUE_LINES}

    #{PLAIN_LANGUAGE_STANDARD}

    Rules for any rewrite:
    - Keep what every entry claims. Keep each negation ("does not", "never"), each condition ("only when", "unless"), and every identifier (a method, column, constant or file name) exactly as written.
    - Never add a claim, a fix or an example the entry does not already make. Never touch code.
    - Keep how sure each claim is. A word that limits a claim ("may", "often", "in some cases") stays, and a vague claim stays vague: "this could get slow with lots of rows" can become "this may get slow with lots of rows", never "this times out with lots of rows".
    - Keep every topic a next step names. Shorten how it says them; never choose some and drop the rest.
    - A list field is rewritten as entries, each with "from": the zero-based indexes of the original entries it replaces. Cite every original index exactly once. Merge entries only when they make the same point, and then report a verbosity issue. Order entries by their first index.
    - Rewrite only the fields that have a problem and leave the others out. If nothing needs changing, return keep.
    - Each issue's evidence quotes the text it is about.

    Work through this internally, then reply with only the JSON verdict, with no text before or after it.
  PROMPT

  Request = Data.define(:purpose, :system, :prompt, :history, :response_schema,
                        :max_tokens, :read_timeout, :cache_system, :single_attempt, :allow_truncated) do
    def self.build(system:, prompt:, purpose: nil, **settings)
      defaults = { history: [], response_schema: nil, max_tokens: nil, read_timeout: READ_TIMEOUT,
                   cache_system: false, single_attempt: false, allow_truncated: false }
      new(purpose: purpose, system: system, prompt: prompt, **defaults.merge(settings))
    end

    def worst_case_seconds = AiService.call_worst_case_seconds(read_timeout: read_timeout, single_attempt: single_attempt)
  end

  CALL_PROFILES = {
    "generate_exercise"           => { read_timeout: GENERATION_READ_TIMEOUT, blocking_read_timeout: SYNC_GENERATION_READ_TIMEOUT },
    "retry_section"               => { read_timeout: RETRY_READ_TIMEOUT },
    "review_response"             => { cache_system: true, read_timeout: REVIEW_READ_TIMEOUT },
    "assess_difficulty"           => { max_tokens: DIFFICULTY_ASSESSMENT_MAX_TOKENS },
    "generate_concept_reference"  => { read_timeout: CONCEPT_REFERENCE_READ_TIMEOUT },
    "generate_recognition_guide"  => { read_timeout: CONCEPT_REFERENCE_READ_TIMEOUT },
    "explain_concept_differently" => { max_tokens: CONCEPT_ALTERNATE_MAX_TOKENS },
    "explain_differently"         => {},
    "review_follow_up"            => {},
    "duck_thread"                 => { max_tokens: DUCK_RESPONSE_MAX_TOKENS, cache_system: true, allow_truncated: true },
    "pseudocode_critique"         => { max_tokens: PSEUDOCODE_CRITIQUE_MAX_TOKENS },
    "pseudocode_translate"        => {},
    "judge_section"               => { max_tokens: JUDGE_MAX_TOKENS },
    "judge_review"                => { max_tokens: REVIEW_JUDGE_MAX_TOKENS, read_timeout: REVIEW_JUDGE_READ_TIMEOUT, single_attempt: true }
  }.freeze

  def self.judged_on?(date) = date.on_weekday?

  def self.worst_case_seconds_for(purpose)
    profile = CALL_PROFILES.fetch(purpose)
    call_worst_case_seconds(read_timeout: profile.fetch(:read_timeout, READ_TIMEOUT), single_attempt: profile.fetch(:single_attempt, false))
  end

  JUDGED_GENERATION_BUDGET = worst_case_seconds_for("generate_exercise") +
                             worst_case_seconds_for("judge_section") +
                             ([ DailyPlan::DAILY_JUDGE_RETRIES, DailyPlan::ROTATED_JUDGE_RETRIES ].max *
                               (worst_case_seconds_for("retry_section") + worst_case_seconds_for("judge_section"))) +
                             (ExerciseSection.all.any?(&:rejudge_edits?) ? worst_case_seconds_for("judge_section") : 0)

  def self.request_for(purpose, system:, prompt:, history: [], response_schema: nil, blocking: false)
    profile  = CALL_PROFILES.fetch(purpose)
    settings = profile.except(:blocking_read_timeout)
    if blocking
      settings[:read_timeout] = profile.fetch(:blocking_read_timeout) { raise ArgumentError, "#{purpose} has no blocking read timeout" }
    end
    Request.build(purpose: purpose, system: system, prompt: prompt, history: history, response_schema: response_schema, **settings)
  end

  SCENARIO_DOMAINS = %w[
    background_job_processing api_versioning_and_deprecation
    activerecord_query_construction component_state_management
    data_export_and_reporting webhook_delivery rate_limiting
    multi_tenant_data_isolation legacy_graphql_maintenance
  ].freeze

  EVERYDAY_SCENARIO_DOMAINS = %w[
    shared_grocery_list recipe_box_and_meal_planner gym_workout_log
    library_book_checkout pet_adoption_listings household_chore_rota
    book_club_reading_list plant_watering_reminders event_rsvp_list
    personal_savings_goals
  ].freeze

  LEGACY_GRAPHQL_SCENARIO_GUIDANCE =
    "Use a legacy GraphQL maintenance scenario (e.g. \"a legacy GraphQL layer needs a fix\") only rarely — " \
    "at most roughly 1 in every 8-10 sessions — purely as scenario framing, never as the tagged concept.".freeze

  SCENARIO_POOLS = {
    general: {
      domains:    SCENARIO_DOMAINS,
      intro:      "real, job-adjacent flavors",
      adaptation: "a Rails day's \"component state management\" becomes a service/controller state concern instead",
      rule:       nil,
      legacy:     LEGACY_GRAPHQL_SCENARIO_GUIDANCE
    },
    everyday: {
      domains:    EVERYDAY_SCENARIO_DOMAINS,
      intro:      "everyday settings people already know from daily life",
      adaptation: "a Rails day's \"shared grocery list\" is the model and controller that store and update the list",
      rule:       "Keep the setting's own words plain and familiar: no business back-office terms such as invoices, " \
                  "ledgers, tenants, CSV exports or webhooks, and solving a section must never require knowing how " \
                  "a company's internal systems work.",
      legacy:     nil
    }
  }.freeze

  LANGUAGE_PROMPTS = {
    "ruby_rails" => {
      label:             "Ruby/Rails",
      coach:             "Rails",
      test_framework:    "an RSpec-style",
      schema_artifact:   "a Rails migration",
      focus:             "real Rails patterns: N+1 queries, idempotency, background jobs, authorization, service objects, query objects, policy objects."
    },
    "javascript" => {
      label:             "JavaScript/React",
      coach:             "JavaScript/React",
      test_framework:    "a Jest/Vitest-style",
      schema_artifact:   "a Prisma schema change, with the migration it generates",
      focus:             "real JavaScript/React patterns: closures, async/event-loop pitfalls, prototypal inheritance, `this` binding, and hooks/re-renders."
    },
    "architecture" => {
      label:    "language-agnostic",
      coach:    "software architecture",
      focus:    "system-design tradeoffs: service boundaries, consistency, failure modes, scale, coupling."
    },
    "plan_review" => {
      label:    "language-agnostic",
      coach:    "engineering plan review",
      focus:    "spotting flaws in a written implementation plan before it's built: unjustified complexity, scope creep, and unflagged behavior changes."
    },
    "ambiguity_hunt" => {
      label:    "language-agnostic",
      coach:    "requirements analysis",
      focus:    "interrogating an underspecified feature request: missing scope boundaries, unhandled edge cases, and unstated success criteria."
    },
    "pseudocode_to_code" => {
      label:    "language-agnostic",
      coach:    "algorithm design",
      focus:    "turning an informal plan into something that actually works: base cases, empty input, boundaries, ordering, and the failure paths a plan leaves undefined."
    }
  }.freeze

  CONCEPT_REFERENCE_FIELDS = %w[tagline explanation code_example senior_lens].freeze

  WORKED_EXAMPLE_BOUND = "At most the two fragments plus four sentences of prose.".freeze

  CONCEPT_GUIDE_FIELDS = %w[guide_plain_language guide_worked_example guide_pitfalls].freeze

  LADDER_FIELD_FOR      = KindDifficulty::LEVELS.index_with { |level| "ladder_#{level}" }.freeze
  CONCEPT_LADDER_FIELDS = LADDER_FIELD_FOR.values.freeze

  MAX_LADDER_RUNG_LENGTH = 300

  MAX_LADDER_GUIDANCE_CHARS = 54_000

  MAX_CONCEPT_GUIDE_LENGTH = 4_000

  CONCEPT_REFERENCE_SCOPE = <<~SCOPE.chomp
    This is a stable explanation an engineer returns to across repeat exposure —
    not tied to any single problem.
  SCOPE

  RECOGNITION_GUIDE_FIELDS = %w[questions contrast misfires].freeze

  RECOGNITION_GUIDE_SCOPE = <<~SCOPE.chomp
    This teaches a PROCESS for recognizing the category, never an ANSWER.
    - Good: "ask whether this interface hides what it should, or makes every caller repeat the same decision."
    - Bad: defining any one concept in the list, such as "shallow_module means the interface is as complex as the implementation". Each concept already has its own reference.
    - Bad: anything that tells the reader what to look for in a particular problem they may be given. Never name or describe a specific planted defect, exercise, or answer.
    It is a lens the reader carries into any problem, not a hint about one.
  SCOPE

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

  JudgedSet = Data.define(:problem_set, :dropped_sections, :outcomes, :plan_notes)

  Draft = Data.define(:problem_set, :plan, :kinds, :difficulty, :ladders, :history,
                      :suggested_concepts, :unusable_sections)
  private_constant :Draft

  def generate_exercise(user, language: user.language_for_today, blocking: false)
    generate_unjudged_exercise(user, language: language, blocking: blocking).problem_set
  end

  def generate_unjudged_exercise(user, language: user.language_for_today, blocking: false, deadline: GenerationDeadline::NONE)
    draft   = draft_exercise(user, language: language, blocking: blocking, deadline: deadline)
    planned = draft.kinds.map(&:key)
    dropped = draft.unusable_sections.select { |section| planned.include?(section.key) }
    finish_generation(user, language, draft, draft.problem_set,
                      dropped_concepts: dropped.to_h { |section| [ section.key, section.concept ] })
    JudgedSet.new(problem_set: draft.problem_set, dropped_sections: dropped.map(&:key), outcomes: {},
                  plan_notes: draft.plan.notes)
  end

  def generate_judged_exercise(user, language: user.language_for_today, deadline: GenerationDeadline::NONE)
    draft = draft_exercise(user, language: language, blocking: false, deadline: deadline)
    JudgedGeneration.call(
      user: user, language: language, draft: draft,
      providers: -> { fresh_service.judged_generation_provider(deadline) },
      finish: ->(set, **logs) { finish_generation(user, language, draft, set, **logs) }
    )
  end

  def review_sections(user, exercise, daily_response, sections:)
    ReviewGrading.call(
      user: user, exercise: exercise, response: daily_response, sections: sections,
      coach: config_for(exercise.language)[:coach], providers: -> { fresh_service.review_grading_provider }
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
    config = config_for(language)

    result = call_and_log(user, AiService.request_for("generate_concept_reference",
      system: "You are a senior #{config[:coach]} engineer writing a concise, durable reference for one concept. Return ONLY valid JSON.",
      prompt: build_concept_reference_prompt(concept, language)
    ))

    reference = parse_json_object(result[:text], subject: "concept reference")

    missing = CONCEPT_REFERENCE_FIELDS.reject { |field| reference[field].is_a?(String) && reference[field].strip.present? }
    if missing.any?
      raise ProviderError::InvalidResponseError, "Concept reference missing required field(s): #{missing.join(', ')}"
    end

    normalize_optional_reference_fields!(reference)

    reference
  end

  def generate_recognition_guide(user, group_key)
    result = call_and_log(user, AiService.request_for("generate_recognition_guide",
      system: "You are a senior engineer writing a short, durable piece on how to recognize one category of problem. Return ONLY valid JSON.",
      prompt: build_recognition_guide_prompt(group_key)
    ))

    guide = parse_json_object(result[:text], subject: "recognition guide")
    RECOGNITION_GUIDE_FIELDS.each { |field| guide[field] = usable_optional_text(guide[field], MAX_CONCEPT_GUIDE_LENGTH) }

    missing = RECOGNITION_GUIDE_FIELDS.select { |field| guide[field].nil? }
    raise ProviderError::InvalidResponseError, "Recognition guide missing usable field(s): #{missing.join(', ')}" if missing.any?

    guide.slice(*RECOGNITION_GUIDE_FIELDS)
  end

  def explain_concept_differently(user, reference, prior_alternates: [])
    coach = config_for(reference.language)[:coach]

    already_read = CONCEPT_REFERENCE_FIELDS
      .map { |field| "#{field}: #{reference.public_send(field)}" }
      .join("\n")

    result = call_and_log(user, AiService.request_for("explain_concept_differently",
      system: "You are a senior #{coach} engineer re-teaching one concept to an engineer for whom the standard reference did not land. Return plain prose — no JSON, no markdown fences.\n\n#{UserText::PROMPT_RULE}",
      prompt: <<~PROMPT
        The concept: "#{reference.concept}"

        The reference they have already read:
        #{already_read}

        #{prior_framings(prior_alternates)}

        #{self.class.explain_differently_standard("concept")}
        #{CONCEPT_REFERENCE_SCOPE} Teach the concept itself; never solve, hint at,
        or refer to any particular exercise. Two short paragraphs at most.

        #{PLAIN_LANGUAGE_STANDARD}
      PROMPT
    ))

    text_or_raise(result, subject: "alternate concept explanation")
  end

  def explain_differently(user, exercise, daily_response, section:, prior_alternates: [])
    coach   = config_for(exercise.language)[:coach]
    review  = daily_response.ai_review&.dig(section) || {}
    missed  = DailyResponse.review_points(review["missed"])

    result = call_and_log(user, AiService.request_for("explain_differently",
      system: "You are a senior #{coach} engineer re-explaining one point to an engineer who did not follow the first explanation. Return plain prose — no JSON, no markdown fences.\n\n#{UserText::PROMPT_RULE}",
      prompt: <<~PROMPT
        The engineer was asked: #{exercise.problem_set.dig(section, "question")}
        #{UserText.labelled("Their answer:", daily_response.answer_for(section))}

        What they missed:
        #{missed.any? ? missed.map { |m| "- #{m}" }.join("\n") : "- (nothing recorded)"}

        #{prior_framings(prior_alternates)}

        #{self.class.explain_differently_standard("point")}
        Two short paragraphs at most.

        #{PLAIN_LANGUAGE_STANDARD}
      PROMPT
    ))

    text_or_raise(result, subject: "alternate explanation")
  end

  def answer_follow_up(user, exercise, daily_response, section:, question:, thread: [])
    coach  = config_for(exercise.language)[:coach]
    review = daily_response.ai_review&.dig(section) || {}

    review_summary = DailyResponse::AI_REVIEW_FIELDS.keys.filter_map { |key|
      points = DailyResponse.review_points(review[key])
      "#{DailyResponse.ai_review_label(key, locale: :en)}: #{points.join('; ')}" if points.any?
    }.join("\n")

    result = call_and_log(user, AiService.request_for("review_follow_up",
      system: <<~SYSTEM,
        You are a senior #{coach} engineer answering a follow-up question about feedback you already gave. Return plain prose — no JSON, no markdown fences.

        #{UserText::PROMPT_RULE}

        #{PLAIN_LANGUAGE_STANDARD}

        The original exercise asked: #{exercise.problem_set.dig(section, "question")}

        The review you gave:
        #{review_summary.presence || "(no detail recorded)"}
      SYSTEM
      history: UserText.tag_history(thread, limit: UserText::MAX_QUESTION_LENGTH),
      prompt: <<~PROMPT
        #{UserText.labelled("Their answer was:", daily_response.answer_for(section))}

        #{UserText.labelled("Their new question:", question, blank: "(none asked)",
                            limit: UserText::MAX_QUESTION_LENGTH)}

        Answer it directly. Stay on this concept — if they drift far off topic, say
        so briefly and bring it back. Two short paragraphs at most.
      PROMPT
    ))

    text_or_raise(result, subject: "follow-up answer")
  end

  def duck_response(user, exercise, section:, message:, thread: [])
    result = call_and_log(user, AiService.request_for("duck_thread",
      system: "#{DUCK_SYSTEM_PROMPT}\n\n#{UserText::PROMPT_RULE}\n\nThe exercise section:\n#{duck_section_context(exercise, section)}",
      history: UserText.tag_history(thread),
      prompt: <<~PROMPT
        Their new message:
        #{UserText.tagged(message, blank: "(nothing said)")}

        Respond as their Socratic thinking partner, following your system instructions exactly.
      PROMPT
    ))

    text = text_or_raise(result, subject: "duck response")
    result[:truncated] ? "#{text}…" : text
  end

  def critique_pseudocode(user, exercise, section:, pseudocode:)
    result = call_and_log(user, AiService.request_for("pseudocode_critique",
      system: "#{PSEUDOCODE_CRITIQUE_SYSTEM_PROMPT}\n\n#{UserText::PROMPT_RULE}",
      prompt: build_pseudocode_critique_prompt(exercise, section, pseudocode)
    ))

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
    result = call_and_log(user, AiService.request_for("pseudocode_translate",
      system: "#{PSEUDOCODE_TRANSLATE_SYSTEM_PROMPT}\n\n#{UserText::PROMPT_RULE}",
      prompt: build_pseudocode_translate_prompt(exercise, section, pseudocode)
    ))

    code = UserText.normalize(text_or_raise(result, subject: "pseudocode translation"))
    if code.length > MAX_GENERATED_CODE_LENGTH
      raise ProviderError::InvalidResponseError,
            "Pseudocode translation came back too long to be usable (#{code.length} characters)"
    end

    code
  end

  def judge_section(user, kind, section, rung:, locked:, deadline: GenerationDeadline::NONE)
    visible = section.except(*ExerciseSection.all_answer_key_fields, *ProblemSetIngest::SERVER_STAMPS)
    request = AiService.request_for("judge_section", response_schema: JudgeVerdict.schema_for(kind), system: JUDGE_SYSTEM_PROMPT,
                                                     prompt: judge_prompt(kind, visible, rung: rung, locked: locked))
    result = call_and_log(user, request, deadline: deadline)
    raw = parse_json_object(result[:text], subject: "#{kind.key} verdict", log_raw: kind.judge_solve_options.nil?)
    JudgeVerdict.parse(raw, kind: kind)
  end

  def judge_review_prose(user, kind, review, coach:)
    projection = ReviewProseVerdict.project(review)
    result = call_and_log(user, AiService.request_for("judge_review",
      response_schema: ReviewProseVerdict.schema,
      system: REVIEW_PROSE_JUDGE_SYSTEM_PROMPT,
      prompt: review_prose_prompt(kind, coach, projection)
    ))
    raw = parse_json_object(result[:text], subject: "review prose verdict", log_raw: false)
    ReviewProseVerdict.parse(raw, projection: projection)
  end

  def self.config_for(language)
    LANGUAGE_PROMPTS.fetch(language) do
      raise SetupError, "Unsupported generation language: #{language.inspect}"
    end
  end

  def self.error_code_for(error)
    case error
    when ProviderError::AuthenticationError  then "authentication"
    when ProviderError::RateLimitError       then "rate_limit"
    when ProviderError::BillingError         then "out_of_credit"
    when ProviderError::TrialEndedError      then "trial_ended"
    when ProviderError::TrialAllowanceError  then "trial_allowance_used"
    when ProviderError::InvalidResponseError then "invalid_response"
    else                                          "other"
    end
  end

  def self.failure_code_for(error)
    case error
    when ProviderError::RateLimitError         then "rate_limit"
    when ProviderError::AuthenticationError    then "authentication"
    when ProviderError::BillingError           then "out_of_credit"
    when ProviderError::TimeoutError           then "timeout"
    when ProviderError::NetworkError           then "network"
    when ProviderError::TruncatedResponseError then "truncated"
    when ProviderError::InvalidResponseError   then "invalid_response"
    when ProviderError::RefusalError           then "refusal"
    else                                            "provider_error"
    end
  end

  def self.judge_fallback_reason(error)
    case error
    when JudgeVerdict::Invalid, ReviewProseVerdict::Invalid then "invalid_output"
    when ProviderError::TruncatedResponseError              then "truncated"
    when ProviderError::InvalidResponseError                then "invalid_json"
    when ProviderError::RefusalError                        then "refusal"
    when ProviderError::DeadlineError                       then ProviderError::DeadlineError::FALLBACK_REASON
    when ProviderError::TimeoutError, Timeout::Error        then "timeout"
    else                                                         http_status_code_for(error) || error_code_for(error)
    end
  end

  def self.http_status_code_for(error)
    "http_#{error.http_status}" if error.instance_of?(ProviderError) && error.http_status
  end

  protected

  def judged_generation_provider(deadline = GenerationDeadline::NONE)
    JudgedGeneration::Provider.new(
      judge_section: ->(*args, **options) { judge_section(*args, **options, deadline: deadline) },
      retry_section: ->(*args) { retry_section(*args, deadline: deadline) }
    )
  end

  private

  def review_prose_prompt(kind, coach, projection)
    <<~PROMPT
      Section kind: #{kind.key}
      The review is written for an engineer working in #{coach}.
      Each list field is an array; an entry's index is its zero-based position.

      The review's prose:
      #{JSON.pretty_generate(projection)}
    PROMPT
  end

  def judge_prompt(kind, visible, rung:, locked:)
    <<~PROMPT
      Section kind: #{kind.key}
      The learner's task for this kind: #{kind.judge_task}
      #{kind.discovery? ? "This is a discovery task: wording that names where the issue is defeats it." : "Naming the concept is expected for this kind."}
      Tagged concept: #{visible["concept"]}
      Pitched at: #{rung}#{locked ? " (locked: this level was asked for unconditionally)" : ""}
      Level meaning: #{KindDifficulty::LEVEL_DEFINITIONS.fetch(rung)}
      Prose fields you may rewrite: #{kind.prose_fields.join(', ')}
      Every other field is the artifact and must not change.
      #{judge_guidance_block(kind)}
      The section as delivered:
      #{JSON.pretty_generate(visible)}
    PROMPT
  end

  def judge_guidance_block(kind)
    kind.judge_guidance ? "\n#{kind.judge_guidance}\n" : ""
  end

  def draft_exercise(user, language:, blocking:, deadline: GenerationDeadline::NONE)
    require_supported_language!(language)
    plan       = DailyPlan.for(user, language: language)
    log_set_size(user, plan.size)
    history    = user.recent_performance
    difficulty = KindDifficulty.for(user)
    kinds      = plan.kinds
    ladders    = ladders_for(difficulty.rungs_for(kinds, skill_level: user.skill_level), language, plan.code_review_mode)
    prompt     = generation_prompt(user, language, plan: plan, history: history, difficulty: difficulty, ladders: ladders)

    request = AiService.request_for("generate_exercise", blocking: blocking, system: build_system_prompt(language),
                                                         prompt: prompt.render)
    result = call_and_log(user, request, deadline: deadline)

    ingested = ProblemSetIngest.call(
      parse_json_object(result[:text], subject: "problem set", log_raw: false),
      language: language, expected_keys: kinds.map(&:key), daily: plan.daily_kinds, code_review_source: plan.code_review_source,
      pitched_at: difficulty.rungs(skill_level: user.skill_level), eased_for: eased_concepts_for(plan, difficulty)
    )

    log_unusable_sections(user, ingested.unusable_sections)
    Draft.new(problem_set: ingested.problem_set, plan: plan, kinds: kinds, difficulty: difficulty,
              ladders: ladders, history: history,
              suggested_concepts: ingested.suggested_concepts, unusable_sections: ingested.unusable_sections)
  end

  def generation_prompt(user, language, plan:, history:, difficulty:, ladders:)
    GenerationPrompt.new(user, language, plan: plan, history: history, difficulty: difficulty, ladders: ladders,
                         retention_annotation: method(:annotate_retention_concept))
  end

  def log_unusable_sections(user, unusable)
    unusable.each do |section|
      Rails.logger.warn("[unusable_section] user=#{user.id} section=#{section.key} reason=#{section.reason}")
    end
  end

  def finish_generation(user, language, draft, set, dropped_concepts: {}, judge: nil, unhosted: [])
    plan = draft.plan
    record_suggested_concepts(draft.suggested_concepts)

    fourth_dropped, language_dropped = dropped_concepts
      .partition { |key, _| ExerciseSection.fourths.include?(ExerciseSection.find(key)) }.map(&:to_h)
    log_retention(user, language, plan.due_checks, set, plan.code_review_mode, dropped: language_dropped)
    if plan.fourth
      log_retention(user, DailyPlan::FOURTH_BUCKET_FOR.fetch(plan.fourth), plan.fourth_due_checks,
                    set, plan.code_review_mode, dropped: fourth_dropped)
    end
    log_waiting_retention(user, plan.waiting_checks)
    log_shared_concept(user, plan, set)
    log_coverage(user, plan.coverage)
    log_difficulty_diagnostics(user, language, plan, set, draft.history,
                               kinds: draft.kinds, difficulty: draft.difficulty, ladders: draft.ladders,
                               judge: judge, unhosted: unhosted)
  end

  def retry_section(user, language, draft, kind, concept, deadline: GenerationDeadline::NONE)
    prompt = generation_prompt(user, language, plan: draft.plan, history: draft.history, difficulty: draft.difficulty,
                               ladders: retry_ladders(user, language, draft, kind))
    request = AiService.request_for("retry_section", system: build_system_prompt(language),
                                                     prompt: prompt.render(only: kind, fixed_concept: concept))
    result = call_and_log(user, request, deadline: deadline.leaving(AiService.worst_case_seconds_for("judge_section")))

    ProblemSetIngest.call(
      parse_json_object(result[:text], subject: "#{kind.key} retry", log_raw: false), language: language,
      expected_keys: [ kind.key ], daily: draft.plan.daily_kinds, fixed_concepts: { kind.key => concept },
      code_review_source: draft.plan.code_review_source,
      pitched_at: { kind.key => draft.difficulty.rung_for(kind, skill_level: user.skill_level) },
      eased_for: eased_concepts_for(draft.plan, draft.difficulty).slice(kind.key)
    ).problem_set[kind.key]
  end

  def retry_ladders(user, language, draft, kind)
    ladders_for(draft.difficulty.rungs_for([ kind ], skill_level: user.skill_level), language, draft.plan.code_review_mode)
  end

  def normalize_optional_reference_fields!(reference)
    CONCEPT_GUIDE_FIELDS.each { |field| reference[field] = usable_optional_text(reference[field], MAX_CONCEPT_GUIDE_LENGTH) }
    CONCEPT_LADDER_FIELDS.each { |field| reference[field] = usable_optional_text(reference[field], MAX_LADDER_RUNG_LENGTH) }
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

  def duck_section_context(exercise, section)
    data = exercise.problem_set.dig(section.to_s) || {}

    [
      ("Title: #{data["title"]}" if data["title"].present?),
      ("Scenario: #{data["scenario"]}" if data["scenario"].present?),
      ("Why it exists: #{data["why"]}" if data["why"].present?),
      ("Question: #{data["question"]}" if data["question"].present?),
      ("Options: #{Array(data["options"]).join(" / ")}" if data["options"].present?),
      ("Code snippet:\n#{data["snippet"]}" if data["snippet"].present?),
      ("Current schema, as the table stands today:\n#{data["current_schema"]}" if data["current_schema"].present?),
      ("Starter code:\n#{data["starter_code"]}" if data["starter_code"].present?),
      ("Plan excerpt:\n#{data["plan_excerpt"]}" if data["plan_excerpt"].present?),
      ("The problem to plan:\n#{data["problem_statement"]}" if data["problem_statement"].present?),
      ("Feature request:\n#{data["request"]}" if data["request"].present?),
      ("Piece A:\n#{data["piece_a"]}" if data["piece_a"].present?),
      ("Piece B:\n#{data["piece_b"]}" if data["piece_b"].present?),
      duck_parsons_blocks(data)
    ].compact.join("\n")
  end

  def duck_parsons_blocks(data)
    blocks = data["blocks"]
    return unless blocks.is_a?(Array) && blocks.any?

    order = scrambled_display_order(data["display_order"], blocks.size)
    return "Blocks (order withheld):\n#{blocks.map(&:to_s).sort.map { |b| "- #{b}" }.join("\n")}" unless order

    lines = order.map.with_index { |block_index, position| "#{position + 1}. #{blocks[block_index]}" }
    "Blocks, in the learner's current on-screen order (NOT the correct order):\n#{lines.join("\n")}"
  end

  def scrambled_display_order(display_order, block_count)
    order = ExerciseSection::ParsonsProblem.normalize_order(Array(display_order), block_count)
    return if order.empty? || order == (0...block_count).to_a

    order
  end

  def build_pseudocode_critique_prompt(exercise, section, pseudocode)
    data = exercise.problem_set[section.to_s] || {}

    <<~PROMPT
      The problem they are planning:
      #{data["problem_statement"]}

      Their pseudocode:
      #{UserText.tagged(pseudocode)}

      Apply your standard exactly as stated in your system instructions:
      #{ExerciseSection::PseudocodeToCode.gap_standard}
    PROMPT
  end

  def build_pseudocode_translate_prompt(exercise, section, pseudocode)
    data = exercise.problem_set[section.to_s] || {}

    <<~PROMPT
      Target language: #{config_for(exercise.language)[:label]}.

      The problem they were planning, for naming only — never for filling gaps:
      #{data["problem_statement"]}

      Their pseudocode, to transcribe literally:
      #{UserText.tagged(pseudocode)}
    PROMPT
  end

  def log_pseudocode_critique(user, gaps_found, gaps)
    Rails.logger.info(
      "[pseudocode] user=#{user.id} date=#{Date.current} phase=critique " \
      "gaps_found=#{gaps_found} gaps=#{gaps.size}"
    )
  end

  def prior_framings(prior_alternates)
    return "No alternate framing has been given yet." if prior_alternates.empty?

    "Framings already given (do NOT reprise these angles or analogies):\n" +
      prior_alternates.map.with_index(1) { |a, i| "#{i}. #{UserText.tagged(a, blank: '')}" }.join("\n")
  end

  def text_or_raise(result, subject:)
    text = result[:text].to_s.strip
    raise ProviderError::InvalidResponseError, "Provider returned an empty #{subject}" if text.blank?
    text
  end

  def error_code_for(error) = self.class.error_code_for(error)

  def require_supported_language!(language) = config_for(language)

  def config_for(language) = self.class.config_for(language)

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

  def log_retention(user, bucket, due_checks, problem_set, code_review_mode, dropped: {})
    return if due_checks.empty?

    offered = due_checks.map(&:concept)
    tagged  = problem_set.values.filter_map { |s| s["concept"] if s.is_a?(Hash) }
    honored = offered & tagged

    Rails.logger.info(
      "[retention] user=#{user.id} date=#{Date.current} bucket=#{bucket} " \
      "code_review_mode=#{code_review_mode} " \
      "offered=#{offered.join(',').presence || '-'} " \
      "honored=#{honored.join(',').presence || '-'} " \
      "tagged=#{tagged.join(',').presence || '-'} " \
      "dropped=#{dropped.map { |key, concept| "#{key}:#{concept}" }.join(',').presence || '-'}"
    )
  end

  def log_set_size(user, size)
    Rails.logger.info("[set_size] user=#{user.id} date=#{Date.current} #{size.diagnostics.to_json}")

    previous = user.daily_exercises.planned_size_before(Date.current)
    return if previous.nil? || previous == size.count

    Rails.logger.info("[set_size] user=#{user.id} from=#{previous} to=#{size.count} reason=#{size.reason}")
  end

  def log_coverage(user, coverage)
    return if coverage.nil?

    Rails.logger.info("[coverage] user=#{user.id} kind=#{coverage.kind.key} reason=#{coverage.reason}")
  end

  def log_shared_concept(user, plan, problem_set)
    concept = plan.shared_concept
    return if concept.nil?

    Rails.logger.info(
      "[shared_concept] user=#{user.id} concept=#{concept} reason=reduced_tier " \
      "honored=#{ExerciseSection.daily_sections_share?(problem_set, concept, daily: plan.daily_kinds)}"
    )
  end

  def log_waiting_retention(user, waiting)
    return if waiting.empty?

    entries = waiting.map { |check| "#{check[:bucket]}:#{check[:concept]}(#{check[:reason]})" }
    Rails.logger.info("[retention] user=#{user.id} date=#{Date.current} waiting=#{entries.join(',')}")
  end

  def log_difficulty_diagnostics(user, language, plan, problem_set, history, kinds:, difficulty:, ladders:,
                                 judge: nil, unhosted: [])
    requested = {
      skill_level: user.skill_level,
      code_review_mode: plan.code_review_mode,
      code_review_source: plan.code_review_source&.id,
      scenario_flavor: plan.scenario_flavor,
      daily_kinds: plan.daily_kinds.map(&:key),
      pattern: plan.rotation[:pattern],
      third: plan.rotation[:third],
      fourth: plan.fourth,
      section_count: kinds.size,
      reinforcement: plan.reinforcement,
      due_checks: plan.due_checks.map(&:concept),
      established: plan.established.map(&:concept),
      shared_concept: plan.shared_concept,
      coverage: plan.coverage && { kind: plan.coverage.kind.key, reason: plan.coverage.reason },
      size: plan.size.diagnostics,
      recent_performance: history
    }
    rungs = difficulty.rungs_for(kinds, skill_level: user.skill_level)
    requested.merge!(kind_difficulty_diagnostics(rungs, difficulty, ladders, language, plan.code_review_mode, problem_set))

    payload = {
      event: "generation",
      user_id: user.id,
      date: Date.current.to_s,
      language: language,
      requested: requested,
      delivered: without_answer_key(problem_set),
      judge: judge,
      unhosted: unhosted
    }

    Rails.logger.info("[difficulty_diagnostics] #{payload.to_json}")
  end

  def eased_concepts_for(plan, difficulty)
    reduced_main   = reduced_concepts(plan.reinforcement)
    reduced_fourth = reduced_concepts(plan.fourth_reinforcement)

    ExerciseSection.all.reject { |kind| difficulty.locked?(kind) }.to_h do |kind|
      [ kind.key, kind.fourth? ? reduced_fourth : reduced_main ]
    end
  end

  def reduced_concepts(entries)
    entries.select { |h| h[:tier] == "reduced" }.map { |h| h[:concept] }
  end

  def kind_difficulty_diagnostics(rungs, difficulty, ladders, language, mode, problem_set)
    per_kind = rungs.to_h do |kind, rung|
      vocabulary = ConceptVocabulary.selectable_for_section(kind.key, language, mode: mode, rung: rung)
      grounded   = vocabulary & ladders.fetch(rung, {}).keys
      chosen     = problem_set.dig(kind.key, "concept")
      [ kind.key, { level: rung, targeted: difficulty.targeted?(kind), locked: difficulty.locked?(kind),
                    ladder_coverage: "#{grounded.size}/#{vocabulary.size}",
                    chosen_concept: chosen, chosen_grounded: grounded.include?(chosen) } ]
    end

    { kind_difficulty: per_kind,
      kind_difficulty_chars: GenerationPrompt::DifficultyGuidance.render(rungs: rungs, difficulty: difficulty, ladders: ladders).length }
  end

  def without_answer_key(problem_set)
    problem_set.transform_values do |section|
      section.is_a?(Hash) ? section.except(*ExerciseSection.all_answer_key_fields) : section
    end
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

  def long_running?(request) = request.read_timeout > READ_TIMEOUT

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

  def build_system_prompt(language = "ruby_rails")
    config = config_for(language)

    <<~PROMPT
      You are a senior #{config[:coach]} engineering coach generating personalized daily exercise sets.
      Your goal is to push engineers toward senior-level thinking: not just "what" but "why" and "when not to."
      Focus on #{config[:focus]}
      Return ONLY valid JSON — no markdown fences, no explanation outside the JSON.

      #{UserText::PROMPT_RULE}
    PROMPT
  end

  def ladders_for(rungs, language, code_review_mode)
    requests = rungs.map do |kind, rung|
      { level: rung, bucket: ConceptBucket.for(kind.key, language),
        concepts: ConceptVocabulary.selectable_for_section(kind.key, language, mode: code_review_mode, rung: rung) }
    end
    pairs = requests.flat_map { |request| request[:concepts].map { |concept| [ request[:bucket], concept ] } }.uniq

    references = ConceptReference.where(language: pairs.map(&:first).uniq, concept: pairs.map(&:last).uniq)
                                 .select(&:ladder?)
                                 .index_by { |reference| [ reference.language, reference.concept ] }

    requests.each_with_object({}) do |request, ladders|
      field = LADDER_FIELD_FOR.fetch(request[:level])
      rungs = request[:concepts].filter_map do |concept|
        reference = references[[ request[:bucket], concept ]]
        [ concept, reference.public_send(field).truncate(MAX_LADDER_RUNG_LENGTH) ] if reference
      end.to_h
      (ladders[request[:level]] ||= {}).merge!(rungs)
    end
  end

  def build_review_day_context(coach, exercise, daily_response)
    keys    = exercise.active_section_keys
    ratings = daily_response.section_ratings

    sections = keys.map do |key|
      ExerciseSection.for(key).review_context(
        section: (exercise.problem_set[key] || {}).merge("rounds" => daily_response.pseudocode_round(key)),
        answer: daily_response.answer_for(key), rating: ratings[key]
      )
    end

    others = keys.size - 1
    others_clause =
      case others
      when 0 then "no other sections today"
      when 1 then "the other section is"
      else "the other #{others} sections are"
      end

    <<~CONTEXT
      You are a senior #{coach} engineer giving direct, specific feedback on an engineer's Code Gym answers. You will grade exactly one of the day's #{keys.size} sections in a follow-up instruction — #{others_clause} given here only as context, since each section is rated against its own pitched level. Be honest and constructive. Return JSON.

      #{UserText::PROMPT_RULE}

      #{RATING_RUBRIC}

      #{PLAIN_LANGUAGE_STANDARD}

      #{sections.join("\n\n")}
    CONTEXT
  end

  def build_review_section_prompt(exercise, daily_response, section)
    <<~PROMPT
      Grade ONLY the "#{section}" section from the day's context above.
      Pitched at: #{pitch_line(exercise, daily_response, section)}

      #{section_grading_note(exercise, daily_response, section)}

      Return a single JSON object (NOT wrapped in a "#{section}" key) with:
      - "rating": "beginner" | "developing" | "solid" | "strong"
      - "correct": array of strings — each entry one distinct thing they got right
      - "missed": array of strings — each entry one distinct thing they missed or got wrong
      - "essential_gaps": array of integers — the zero-based positions in "missed" of the entries that are essential gaps; an empty array when none are
      - "better_questions": array of strings — each entry one question they should have asked themselves
      - "next_step": string — one specific thing to study
      - "improved_code": string — #{improved_code_instruction(section)}

      Each array entry must be ONE self-contained idea in one or two sentences. Never pack
      several points into one entry, and never number points inside an entry ("1) ... 2) ...")
      — separate ideas belong in separate entries. Use an empty array when there is nothing to
      say for that field.
    PROMPT
  end

  def pitch_line(exercise, daily_response, section)
    stamped = exercise.problem_set.dig(section, "pitched_at")
    rung = KindDifficulty::LEVELS.include?(stamped) ? stamped : current_rung(daily_response.user, section)
    "#{rung} — #{KindDifficulty::LEVEL_DEFINITIONS.fetch(rung)}"
  end

  def current_rung(user, section)
    difficulty = user ? KindDifficulty.for(user) : KindDifficulty.none
    difficulty.rung_for(ExerciseSection.for(section), skill_level: user&.skill_level)
  end

  def improved_code_instruction(section)
    kind = ExerciseSection.for(section)
    kind.improved_code? ?
      "the #{kind.improved_code_label.downcase} for this section" :
      "must be an empty string for this section"
  end

  def section_grading_note(exercise, daily_response, section)
    ExerciseSection.for(section).grading_note(
      section: exercise.problem_set[section] || {}, answer: daily_response.answer_for(section)
    )
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
      .except(ReviewProseVerdict::ORIGINAL_KEY, "rubric").merge("rubric" => RUBRIC_VERSION)
  end


  def assess_difficulty(user, exercise, sections:)
    result = call_and_log(user, AiService.request_for("assess_difficulty",
      system: build_difficulty_system_prompt(config_for(exercise.language)[:coach]),
      prompt: build_difficulty_prompt(exercise, sections)
    ))

    assessed = parse_json_object(result[:text], subject: "difficulty assessment")
    sections.to_h { |section| [ section, DailyResponse.usable_difficulty(assessed[section]) ] }.compact
  end

  def build_difficulty_system_prompt(coach)
    "You are a senior #{coach} engineer rating how hard each of several practice problems is. " \
    "You are not grading anyone, and you will not be shown anyone's answer. Return JSON."
  end

  def build_difficulty_prompt(exercise, sections)
    material = sections.map { |section| "## #{section}\n#{duck_section_context(exercise, section)}" }

    <<~PROMPT
      Rate the objective difficulty of each problem below, on this scale:
      #{difficulty_scale}

      Judge only the material shown. Weigh how subtle the issue is, how many
      reasoning steps a complete answer takes, and how much the scenario leaves
      unstated. You know nothing about who is answering it, how they have done
      before, or why this problem was chosen for them — none of that is here,
      and none of it belongs in the rating. Two problems about the same idea can
      differ; "#{DailyResponse::DIFFICULTY_LEVELS.first}" is a perfectly good answer.

      Return a single JSON object keyed by the section names below:
      {
        "<section name>": {
          "level": #{DailyResponse::DIFFICULTY_LEVELS.map(&:inspect).join(' | ')},
          "reason": "string — one sentence of at most #{DailyResponse::MAX_DIFFICULTY_REASON_LENGTH} characters naming what makes it that, written for the engineer to read after their review"
        }
      }

      #{material.join("\n\n")}
    PROMPT
  end

  DIFFICULTY_GUIDANCE = {
    "straightforward" => "one thing to notice; a competent engineer finds it on a first read.",
    "moderate"        => "a couple of reasoning steps, or one detail that is easy to skim past.",
    "demanding"       => "the issue is subtle, several steps chain together, or the scenario leaves something material unstated."
  }.freeze

  def difficulty_scale
    DailyResponse::DIFFICULTY_LEVELS
      .map { |level| "- \"#{level}\" — #{DIFFICULTY_GUIDANCE.fetch(level)}" }
      .join("\n")
  end

  def build_concept_reference_prompt(concept, language)
    config = config_for(language)
    medium = ConceptVocabulary.language_agnostic?(language) ? nil : config[:label]

    senior_lens_desc =
      if ConceptVocabulary::ANTI_SHAPE_CONCEPTS.include?(concept)
        "how to catch it early, what it costs to leave in place, and when the cheaper-looking shape is still worth refusing"
      else
        "when to reach for it / tradeoffs"
      end

    <<~PROMPT
      Write a durable reference for the #{config[:coach]} concept: "#{concept}".
      #{CONCEPT_REFERENCE_SCOPE} Be precise and senior-level.

      Then write a longer, plainer-language guide for someone meeting this
      concept in a library rather than in a problem — no exercise in front of
      them, no answer to reach. Thorough but not an essay: each guide field is
      at most two short paragraphs, except guide_worked_example, which carries
      its own bound below.

      This standard applies to the guide fields and the lesson:
      #{PLAIN_LANGUAGE_STANDARD}

      Then write a difficulty ladder: for each of #{KindDifficulty::LEVELS.join(', ')}, what a
      problem about THIS concept looks like at that level. Name its concrete form, never a
      description of the level in general. For missing_index, for example: junior is an
      unindexed foreign key, mid_level is an index the query can't use because it wraps the
      column in a function, senior is composite index column order, principal_engineer is
      the write-cost tradeoff of adding an index. Each rung is one or two sentences, under
      #{MAX_LADDER_RUNG_LENGTH} characters.

      #{concept_lesson_instruction(concept)}

      Return JSON matching this schema exactly:
      {
        "tagline":      "string — bold one-liner",
        "explanation":  "string — 2-3 sentences",
        "code_example": "string — #{code_example_description(medium)}",
        "senior_lens":  "string — #{senior_lens_desc}",
        "guide_plain_language": "string — what this actually is, for a competent engineer who has never met the term",
        "guide_worked_example": "#{worked_example_description(concept, medium)}",
        "guide_pitfalls":       "string — what people get wrong about this, and why the wrong idea is appealing",
      #{LADDER_FIELD_FOR.map { |level, field| %(  "#{field}": "string — a #{level}-level problem about this concept",) }.join("\n")}
        "lesson": #{JSON.generate(ConceptLesson.schema)}
      }
    PROMPT
  end

  def concept_lesson_instruction(concept)
    habits =
      if ConceptVocabulary::TRADEOFF_CONCEPTS.include?(concept)
        "habits: one to #{ConceptLesson::MAX_HABITS} options a team can choose between. Each carries \"catch\": what that option costs."
      else
        "habits: one to #{ConceptLesson::MAX_HABITS} small habits or fixes. Each carries \"catch\": the real limit or cost of that habit, which the reader sees directly after it."
      end

    <<~TEXT.chomp
      Then write a short lesson for someone reading this concept on a phone, under
      "lesson". Every key in it is optional: leave a key out when it does not fit
      this concept, and never pad one to fill it.
      Keep the whole lesson under about #{ConceptLesson::WORD_TARGET} words, in plain prose with no code;
      the code example and the worked example already show the code.
      - definition: one sentence saying what the concept is.
      - comparison: an everyday comparison that maps onto the concept exactly.
      - comparison_limit: one sentence saying where that comparison stops working. Give it with comparison or leave both out; one without the other is dropped.
      - misunderstanding: the most common wrong idea about this concept, and what is true instead.
      - situations: two to #{ConceptLesson::MAX_SITUATIONS} concrete situations where an engineer runs into it, each one short.
      - #{habits}
      - carry_question: one question the reader can ask about their own work.
      - quick_test: a quick way to check their own code or plan for it.
    TEXT
  end

  def build_recognition_guide_prompt(group_key)
    concepts = RecognitionGuide.concepts_for(group_key)

    <<~PROMPT
      Write a short teaching piece on how to recognize one category of problem.

      The category, "#{group_key.humanize}", is about #{RecognitionGuide.subject_for(group_key)}
      The concepts in it are: #{concepts.join(', ')}.
      #{RecognitionGuide.framing_for(group_key)}
      #{recognition_tradeoff_line(concepts)}

      #{RECOGNITION_GUIDE_SCOPE}

      Write for any engineer reading a library, with no exercise in front of them.
      Keep examples language-neutral: plain description, or a few lines of
      pseudocode at most. Invent them; never describe a real exercise.

      This standard applies to every field:
      #{PLAIN_LANGUAGE_STANDARD}

      Return JSON matching this schema exactly:
      {
        "questions": "string — the questions to ask, in the order you would ask them, when reading code or a plan to see whether it has a problem of this kind. At most two short paragraphs.",
        "contrast":  "string — two short invented situations of the same shape: one where those questions turn something up, and a look-alike where they come back clean. Then say which question told them apart. At most two short paragraphs.",
        "misfires":  "string — how this way of looking goes wrong: what it flags that is not a problem, and what it misses. One short paragraph."
      }
    PROMPT
  end

  def recognition_tradeoff_line(concepts)
    choices = concepts & ConceptVocabulary::TRADEOFF_CONCEPTS
    return if choices.empty?

    "Some of these (#{choices.join(', ')}) are choices between two defensible options rather than defects. " \
      "For those, the lens recognizes that a choice is being made and which property of the context decides it, never which side is right."
  end

  def code_example_description(medium)
    return "illustrative pseudocode or a short language-agnostic snippet, ~15 lines" if medium.nil?

    "annotated #{medium} code, ~15 lines"
  end

  def worked_example_description(concept, medium)
    opening = "two short #{medium || 'pseudocode'} fragments of the SAME scenario, " \
              "keeping the same names and shape so the difference reads structurally"

    if ConceptVocabulary::TRADEOFF_CONCEPTS.include?(concept)
      "string — #{opening}: option A, then option B. NEITHER is the corrected version — both are " \
        "legitimate and the choice is context-dependent. Then say in prose what each option buys, what it " \
        "costs, and which property of the context decides between them. #{WORKED_EXAMPLE_BOUND}"
    else
      "string — #{opening}: first the version exhibiting the concept's failure mode, then the " \
        "corrected version of that same scenario. Then say in prose WHY the two relate as a mechanism " \
        "('X causes Y', 'Y is what happens when X breaks down') — never merely that they are " \
        "associated or related. #{WORKED_EXAMPLE_BOUND}"
    end
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

  def record_suggested_concepts(suggestions)
    suggestions.each { |suggestion| record_suggested_concept(suggestion) }
  end

  def record_suggested_concept(suggestion)
    SuggestedConcept.record!(language: suggestion.bucket, name: suggestion.name)
  rescue => e
    Rails.logger.warn("SuggestedConcept recording failed: #{e.message}")
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
