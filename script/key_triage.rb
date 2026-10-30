# Design notes: docs/code-notes/script/key_triage.md
module KeyTriage
  PURPOSE = "triage_solve".freeze
  DEFAULT_SOLVER_MODEL = ClaudeService::MODEL_FOR_PURPOSE.fetch("judge_section")[:model]
  SOLVER_MODELS = ClaudeService::MODEL_FOR_PURPOSE.values.map { |route| route[:model] }.uniq.freeze
  SOLVER_EFFORT = "high".freeze
  MODES = DailyPlan::CODE_REVIEW_MODE_WEIGHTS.keys.freeze
  OUTCOMES = %w[agree disagree unlocated].freeze
  REPLY_FIELDS = %w[issue fix].freeze
  HIDDEN_FROM_SOLVER = %w[concept teaching_note].freeze

  SYSTEM = <<~PROMPT.freeze
    You are an experienced engineer doing a code review exercise. The code holds one planted issue, and your job is to find it.
    Name the one issue that matters most. Quote the code it is in, exactly as shown, in backticks, and never by line number.
    Then give a fix that works as written.
    Reply with JSON only: {"issue":"<what is wrong and where, quoting the code in backticks>","fix":"<the fix>"}
  PROMPT

  SCHEMA = VerdictSchema.closed_object(REPLY_FIELDS.index_with { { "type" => "string" } })

  def self.solve_prompt(kind, section)
    shown = SectionJudgePrompt.visible(kind, section).except(*HIDDEN_FROM_SOLVER)
    { system: SYSTEM, response_schema: SCHEMA, prompt: <<~PROMPT }
      Section kind: #{kind.key}
      The section as the engineer sees it:
      #{JSON.pretty_generate(shown)}
    PROMPT
  end

  def self.reply(raw)
    PlantedKey.fields(raw, REPLY_FIELDS) or raise ProviderError::InvalidResponseError, "The solve reply needs a text issue and fix"
  end

  def self.compare(kind, section, solver_issue, language:)
    solver = located(kind, section, [ solver_issue ], language)
    key    = located(kind, section, kind.quoted_key_texts(section[PlantedKey::FIELD]), language)
    { "triage" => outcome(solver, key), "solver_lines" => lines_by_field(solver), "key_lines" => lines_by_field(key) }
  end

  def self.sheet_sections(entries)
    agreements = entries.select { |entry| entry["triage"] == "agree" }.group_by { |entry| entry["code_review_mode"] }
    entries.reject { |entry| entry["triage"] == "agree" } + agreements.values.map(&:first)
  end

  def self.summary(entries)
    by_mode = MODES.map { |mode| "#{mode} #{counts(entries.select { |entry| entry["code_review_mode"] == mode.to_s })}" }
    lacking = MODES.reject { |mode| entries.any? { |entry| entry["code_review_mode"] == mode.to_s && entry["triage"] == "agree" } }
    [ "triage: #{counts(entries)}", *by_mode.map { |line| "  #{line}" },
      ("no agreement to read for: #{lacking.join(', ')}" if lacking.any?) ].compact
  end

  def self.located(kind, section, texts, language)
    quotes = texts.compact.flat_map { |text| text.scan(PlantedKey::QUOTE).flatten }
                  .select { |quote| KeyQuote.normalize(quote, language: language).length >= PlantedKey::MIN_QUOTE_LENGTH }
    kind.key_context_fields.product(quotes).filter_map do |field, quote|
      range = section[field].is_a?(String) && KeyQuote.find(section[field], quote, language: language)
      [ field, range ] if range
    end
  end

  def self.outcome(solver, key)
    return "unlocated" if solver.empty? || key.empty?

    solver.product(key).any? { |(field, mine), (key_field, theirs)| field == key_field && overlap?(mine, theirs) } ? "agree" : "disagree"
  end

  def self.overlap?(first, second) = first.begin <= second.end && second.begin <= first.end

  def self.lines_by_field(located)
    located.group_by(&:first).transform_values { |pairs| pairs.map { |_, range| range.minmax.uniq.join("-") } }
  end

  def self.counts(entries) = OUTCOMES.map { |outcome| "#{outcome} #{entries.count { |entry| entry["triage"] == outcome }}" }.join(" · ")

  private_class_method :located, :outcome, :overlap?, :lines_by_field, :counts
end
