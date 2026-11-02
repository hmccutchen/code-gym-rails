# Design notes: docs/code-notes/app/models/call_profiles.md
module CallProfiles
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

  DUCK_RESPONSE_MAX_TOKENS = 400

  CONCEPT_ALTERNATE_MAX_TOKENS = 500

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

  JUDGE_MEASURED_MAX_OUTPUT_TOKENS = 654

  JUDGE_MAX_TOKENS = 2_000

  REVIEW_JUDGE_MEASURED_MAX_OUTPUT_TOKENS = 371

  REVIEW_JUDGE_MAX_TOKENS = 1_500

  BY_PURPOSE = {
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

  def self.fetch(purpose) = BY_PURPOSE.fetch(purpose)

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

  def self.worst_case_seconds_for(purpose)
    profile = fetch(purpose)
    call_worst_case_seconds(read_timeout: profile.fetch(:read_timeout, READ_TIMEOUT), single_attempt: profile.fetch(:single_attempt, false))
  end

  JUDGED_GENERATION_BUDGET = worst_case_seconds_for("generate_exercise") +
                             worst_case_seconds_for("judge_section") +
                             ([ DailyPlan::DAILY_JUDGE_RETRIES, DailyPlan::ROTATED_JUDGE_RETRIES ].max *
                               (worst_case_seconds_for("retry_section") + worst_case_seconds_for("judge_section"))) +
                             (ExerciseSection.all.any?(&:rejudge_edits?) ? worst_case_seconds_for("judge_section") : 0)
end
