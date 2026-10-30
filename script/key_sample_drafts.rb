# Design notes: docs/code-notes/script/key_sample_drafts.md
require_relative "key_sheet_export"
require_relative "forced_concept_drafts"
require_relative "key_triage"
require_relative "spend_cap"

class KeySampleDrafts
  KINDS = [ ExerciseSection::SecurityReview, ExerciseSection::PlanReview, ExerciseSection::PseudocodeToCode ].freeze
  TRIAGE_KIND = ExerciseSection::CodeReview
  COUNTS = { drafts: { default: 6, most: 10 }, triage: { default: 30, most: 30 } }.freeze
  ATTEMPTS_PER_SECTION = 2
  APPROX_CHARS_PER_TOKEN = 4
  CAP_CHARS_PER_TOKEN = 3
  RESCUED = [ ProviderError, SetupError, JudgeVerdict::Invalid, *AiService::INFRASTRUCTURE_ERRORS ].freeze

  Tally = Struct.new(:entries, :rejected, :keyless, :failed, :stopped)

  def self.service(api_key, usage, solver_model: KeyTriage::DEFAULT_SOLVER_MODEL, cap: nil)
    unless KeyTriage::SOLVER_MODELS.include?(solver_model)
      raise ArgumentError, "#{solver_model} isn't a solver model: #{KeyTriage::SOLVER_MODELS.join(', ')}"
    end

    solver_route = { model: solver_model, effort: KeyTriage::SOLVER_EFFORT }
    Class.new(ClaudeService) do
      define_method(:log_usage) do |_user, result, purpose:|
        usage << { purpose: purpose, tokens_in: result[:input_tokens].to_i, tokens_out: result[:output_tokens].to_i,
                   cache_read: result[:cache_read_tokens].to_i, cache_write: result[:cache_write_tokens].to_i }
        cap&.record(KeySampleDrafts.call_cost(usage.last, routed_model(purpose)).to_f, purpose)
      end
      define_method(:call_and_log) do |user, request, **options|
        cap&.check!(KeySampleDrafts.request_bound(request, routed_model(request.purpose)))
        super(user, request, **options)
      end
      define_method(:route_for) { |purpose| purpose == KeyTriage::PURPOSE ? solver_route : super(purpose) }
      define_method(:solve_section) do |user, kind, section|
        result = call_and_log(user, AiService::Request.build(purpose: KeyTriage::PURPOSE, **KeyTriage.solve_prompt(kind, section)))
        KeyTriage.reply(parse_json_object(result[:text], subject: "#{kind.key} solve", log_raw: false))
      end
      private :log_usage, :route_for, :call_and_log
    end.new(api_key)
  end

  def self.call_cost(call, model)
    ClaudeService.cost_usd(model: model, input_tokens: call[:tokens_in], output_tokens: call[:tokens_out],
                           cache_read_tokens: call[:cache_read], cache_write_tokens: call[:cache_write])
  end

  # Counts input at fewer characters a token than the plan does, so the guard errs high.
  def self.request_bound(request, model)
    text  = [ request.system, request.prompt, request.response_schema&.to_json, *request.history.map { |turn| turn[:content] } ]
    input = text.compact.sum(&:size) / CAP_CHARS_PER_TOKEN
    call_cost({ tokens_in: input, tokens_out: request.max_tokens || ClaudeService::MAX_TOKENS, cache_read: 0, cache_write: 0 }, model).to_f
  end

  def self.refuse_production!(env = Rails.env)
    raise ArgumentError, "Run this against a local database, never in production" if env.production?
  end

  # Creates the file now, so a bad path fails before any billed call and nothing else can take it.
  def self.reserve_out_path!(path)
    parent = File.realpath(File.dirname(File.expand_path(path)))
    full   = File.join(parent, File.basename(path))
    raise ArgumentError, "Write the drafts outside the repository: #{full}" if "#{full}/".start_with?("#{Rails.root.realpath}/")

    File.open(full, File::WRONLY | File::CREAT | File::EXCL) { }
    full
  rescue Errno::ENOENT
    raise ArgumentError, "No directory for #{path}"
  rescue Errno::EEXIST
    raise ArgumentError, "#{full} already exists"
  end

  def initialize(kind:, language:, count:, service:, out:, triage: false)
    drafted = [ *KINDS, TRIAGE_KIND ]
    raise ArgumentError, "#{kind.key} isn't drafted for the key read: #{drafted.map(&:key).join(', ')}" unless drafted.include?(kind)
    raise ArgumentError, "--triage drafts #{TRIAGE_KIND.key} only" if triage && kind != TRIAGE_KIND

    @triage   = triage
    @kind     = kind
    @language = language
    @count    = count
    @service  = service
    @out      = out
    @user     = User.new(skill_level: KindDifficulty::LEVELS.last)
  end

  def plan
    @out.puts "=== draft_key_samples plan: #{@kind.key}, #{@language} · #{@count} sections · no provider call made ==="
    @out.puts "at most #{attempts} drafts, each judged#{', and each kept one solved' if @triage}: " \
              "at most #{(attempts * 2) + solves} calls, before the client's own retries"
    @out.puts "bound, with every call at its output cap and no caching: $#{format('%.2f', output_cap_cost)}"
  end

  def call(path)
    tally = Tally.new([], 0, 0, [], nil)
    ReviewBaselineExport.read_only do
      attempts.times do |attempt|
        break if tally.entries.size >= @count

        draft_one(attempt, tally, path)
      end
    end
    tally
  rescue SpendCap::Reached => e
    tally.stopped = "Stopped: #{e.message}"
    tally
  ensure
    write(tally, path) if tally
  end

  def summary(tally) = @triage ? KeyTriage.summary(tally.entries) : []

  def cost_line(usage)
    return "no calls made" if usage.empty?

    costs = usage.map { |call| self.class.call_cost(call, @service.model_for(call[:purpose])) }
    price = costs.all? ? "$#{format('%.2f', costs.sum)}" : "unpriced"
    "#{usage.size} calls · #{usage.sum { |call| call[:tokens_in] }} in / #{usage.sum { |call| call[:tokens_out] }} out · #{price}"
  end

  private

  def attempts = @count * ATTEMPTS_PER_SECTION

  def solves = @triage ? attempts : 0

  def mode_for(kept) = (KeyTriage::MODES[kept % KeyTriage::MODES.size] if @kind == TRIAGE_KIND)

  def rung_for(kept) = KindDifficulty::LEVELS[kept % KindDifficulty::LEVELS.size]

  # Offset once per pass through the rungs, so every concept meets every rung.
  def concept_for(attempt, rung, mode)
    concepts = ConceptVocabulary.selectable_for_section(@kind.key, @language, mode: mode, rung: rung) - [ "other" ]
    concepts[(attempt + (attempt / KindDifficulty::LEVELS.size)) % concepts.size]
  end

  def draft_one(attempt, tally, path)
    rung    = rung_for(tally.entries.size)
    mode    = mode_for(tally.entries.size)
    section = @service.send(:retry_section, draft_for(rung, mode), @kind, concept_for(attempt, rung, mode))
    return tally.keyless += 1 unless section.key?(PlantedKey::FIELD)

    verdict = @service.judge_section(@user, @kind, section, rung: rung, locked: true)
    return tally.rejected += 1 if verdict.reject?

    kept = verdict.apply(section)
    tally.entries << entry(kept, rung, verdict).merge(triage_fields(kept, mode))
    write(tally, path)
  rescue *RESCUED => e
    tally.failed << "#{e.class}: #{e.message}"
  end

  def entry(section, rung, verdict)
    KeySheetExport.entry(@kind.key, @language, section).merge("concept" => section["concept"], "rung" => rung,
                                                               "judge" => verdict.status.to_s)
  end

  def triage_fields(section, mode)
    return {} unless @triage

    solved = @service.solve_section(@user, @kind, section)
    { "code_review_mode" => mode.to_s, **KeyTriage.compare(@kind, section, solved["issue"], language: @language), "solver" => solved }
  end

  def write(tally, path)
    sections = @triage ? KeyTriage.sheet_sections(tally.entries) : tally.entries
    File.write(path, JSON.pretty_generate("sections" => sections, "summary" => summary(tally), "rejected" => tally.rejected,
                                          "keyless" => tally.keyless, "failed" => tally.failed, "stopped" => tally.stopped))
  end

  def draft_for(rung, mode)
    ForcedConceptDrafts.rung_draft(@user, @language, rung, kind: @kind, plan: plan_for(mode))
  end

  # Toy and single-file: a RealSource excerpt needs the scenario restore JudgedGeneration does (key_sample_drafts.md).
  def plan_for(mode)
    plan = DailyPlan.for(@user, language: @language)
    mode ? plan.with(code_review_mode: mode, code_review_source: nil, code_review_files: :single) : plan
  end

  def output_cap_cost
    rung  = rung_for(0)
    judge = SectionJudgePrompt.generate(kind: @kind, section: FakeService::EXERCISE_PROBLEM_SET.fetch(@kind.key), rung: rung, locked: true)
    (attempts * (call_cost("retry_section", retry_input_tokens(rung)) +
                 call_cost("judge_section", tokens(judge[:system], judge[:prompt], judge[:response_schema].to_json)))) +
      (solves * call_cost(KeyTriage::PURPOSE, solve_input_tokens))
  end

  def solve_input_tokens
    solve = KeyTriage.solve_prompt(@kind, FakeService::EXERCISE_PROBLEM_SET.fetch(@kind.key))
    tokens(solve[:system], solve[:prompt], solve[:response_schema].to_json)
  end

  def retry_input_tokens(rung)
    measuring = Class.new(@service.class) do
      define_method(:generate_problem_set) do |_user, _purpose, language, prompt, **|
        throw :retry_prompt, build_system_prompt(language) + prompt
      end
    end.new("plan-only")
    tokens(catch(:retry_prompt) { measuring.send(:retry_section, draft_for(rung, mode_for(0)), @kind, concept_for(0, rung, mode_for(0))) })
  end

  def tokens(*texts) = texts.sum(&:size) / APPROX_CHARS_PER_TOKEN

  def call_cost(purpose, input)
    cap = (CallProfiles.fetch(purpose)[:max_tokens] unless purpose == KeyTriage::PURPOSE) || ClaudeService::MAX_TOKENS
    ClaudeService.cost_usd(model: @service.model_for(purpose), input_tokens: input, output_tokens: cap,
                           cache_read_tokens: 0, cache_write_tokens: 0).to_f
  end
end
