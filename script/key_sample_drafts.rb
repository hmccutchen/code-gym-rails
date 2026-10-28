# Design notes: docs/code-notes/script/key_sample_drafts.md
require_relative "key_sheet_export"
require_relative "forced_concept_drafts"

class KeySampleDrafts
  KINDS = [ ExerciseSection::SecurityReview, ExerciseSection::PlanReview, ExerciseSection::PseudocodeToCode ].freeze
  ATTEMPTS_PER_SECTION = 2
  APPROX_CHARS_PER_TOKEN = 4
  RESCUED = [ ProviderError, SetupError, JudgeVerdict::Invalid, *AiService::INFRASTRUCTURE_ERRORS ].freeze

  Tally = Struct.new(:entries, :rejected, :keyless, :failed)

  def self.service(api_key, usage)
    Class.new(ClaudeService) do
      define_method(:log_usage) do |_user, result, purpose:|
        usage << { purpose: purpose, tokens_in: result[:input_tokens].to_i, tokens_out: result[:output_tokens].to_i,
                   cache_read: result[:cache_read_tokens].to_i, cache_write: result[:cache_write_tokens].to_i }
      end
      private :log_usage
    end.new(api_key)
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

  def initialize(kind:, language:, count:, service:, out:)
    raise ArgumentError, "#{kind.key} isn't drafted for the key read: #{KINDS.map(&:key).join(', ')}" unless KINDS.include?(kind)

    @kind     = kind
    @language = language
    @count    = count
    @service  = service
    @out      = out
    @user     = User.new(skill_level: KindDifficulty::LEVELS.last)
  end

  def plan
    @out.puts "=== draft_key_samples plan: #{@kind.key}, #{@language} · #{@count} sections · no provider call made ==="
    @out.puts "at most #{attempts} drafts, each judged: at most #{attempts * 2} calls, before the client's own retries"
    @out.puts "bound, with every call at its output cap and no caching: $#{format('%.2f', output_cap_cost)}"
  end

  def call(path)
    tally = Tally.new([], 0, 0, [])
    ReviewBaselineExport.read_only do
      attempts.times do |attempt|
        break if tally.entries.size >= @count

        draft_one(attempt, tally, path)
      end
    end
    tally
  ensure
    write(tally, path) if tally
  end

  def cost_line(usage)
    return "no calls made" if usage.empty?

    costs = usage.map do |call|
      ClaudeService.cost_usd(model: @service.model_for(call[:purpose]), input_tokens: call[:tokens_in], output_tokens: call[:tokens_out],
                             cache_read_tokens: call[:cache_read], cache_write_tokens: call[:cache_write])
    end
    price = costs.all? ? "$#{format('%.2f', costs.sum)}" : "unpriced"
    "#{usage.size} calls · #{usage.sum { |call| call[:tokens_in] }} in / #{usage.sum { |call| call[:tokens_out] }} out · #{price}"
  end

  private

  def attempts = @count * ATTEMPTS_PER_SECTION

  def rung_for(kept) = KindDifficulty::LEVELS[kept % KindDifficulty::LEVELS.size]

  # Offset once per pass through the rungs, so every concept meets every rung.
  def concept_for(attempt, rung)
    concepts = ConceptVocabulary.selectable_for_section(@kind.key, @language, rung: rung) - [ "other" ]
    concepts[(attempt + (attempt / KindDifficulty::LEVELS.size)) % concepts.size]
  end

  def draft_one(attempt, tally, path)
    rung    = rung_for(tally.entries.size)
    section = @service.send(:retry_section, draft_for(rung), @kind, concept_for(attempt, rung))
    return tally.keyless += 1 unless section.key?(PlantedKey::FIELD)

    verdict = @service.judge_section(@user, @kind, section, rung: rung, locked: true)
    return tally.rejected += 1 if verdict.reject?

    tally.entries << entry(verdict.apply(section), rung, verdict)
    write(tally, path)
  rescue *RESCUED => e
    tally.failed << "#{e.class}: #{e.message}"
  end

  def entry(section, rung, verdict)
    KeySheetExport.entry(@kind.key, @language, section).merge("concept" => section["concept"], "rung" => rung,
                                                               "judge" => verdict.status.to_s)
  end

  def write(tally, path)
    File.write(path, JSON.pretty_generate("sections" => tally.entries, "rejected" => tally.rejected,
                                          "keyless" => tally.keyless, "failed" => tally.failed))
  end

  def draft_for(rung) = ForcedConceptDrafts.rung_draft(@user, @language, rung, kind: @kind)

  def output_cap_cost
    rung  = rung_for(0)
    judge = SectionJudgePrompt.generate(kind: @kind, section: FakeService::EXERCISE_PROBLEM_SET.fetch(@kind.key), rung: rung, locked: true)
    attempts * (call_cost("retry_section", retry_input_tokens(rung)) +
                call_cost("judge_section", tokens(judge[:system], judge[:prompt], judge[:response_schema].to_json)))
  end

  def retry_input_tokens(rung)
    measuring = Class.new(@service.class) do
      define_method(:generate_problem_set) do |_user, _purpose, language, prompt, **|
        throw :retry_prompt, build_system_prompt(language) + prompt
      end
    end.new("plan-only")
    tokens(catch(:retry_prompt) { measuring.send(:retry_section, draft_for(rung), @kind, concept_for(0, rung)) })
  end

  def tokens(*texts) = texts.sum(&:size) / APPROX_CHARS_PER_TOKEN

  def call_cost(purpose, input)
    cap = CallProfiles.fetch(purpose)[:max_tokens] || ClaudeService::MAX_TOKENS
    ClaudeService.cost_usd(model: @service.model_for(purpose), input_tokens: input, output_tokens: cap,
                           cache_read_tokens: 0, cache_write_tokens: 0).to_f
  end
end
