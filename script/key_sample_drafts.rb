# Design notes: docs/code-notes/script/key_sample_drafts.md
require_relative "key_sheet_export"

class KeySampleDrafts
  ATTEMPTS_PER_SECTION = 2
  APPROX_CHARS_PER_TOKEN = 4

  Result = Data.define(:entries, :rejected, :keyless, :failed)

  # A service that keeps each call's usage in memory and records no suggested concept, so a run writes no row.
  def self.service(api_key, usage)
    Class.new(ClaudeService) do
      define_method(:log_usage) do |_user, result, purpose:|
        usage << { purpose: purpose, tokens_in: result[:input_tokens].to_i, tokens_out: result[:output_tokens].to_i,
                   cache_read: result[:cache_read_tokens].to_i, cache_write: result[:cache_write_tokens].to_i }
      end
      define_method(:record_suggested_concept) { |_suggestion| }
      private :log_usage, :record_suggested_concept
    end.new(api_key)
  end

  def self.concepts_for(kind, language, rung)
    ConceptVocabulary.selectable_for_section(kind.key, language, rung: rung) - [ "other" ]
  end

  def self.check_out_path!(path)
    full = File.expand_path(path)
    raise ArgumentError, "Write the drafts outside the repository: #{full}" if full.start_with?("#{Rails.root}/")
    raise ArgumentError, "#{full} already exists" if File.exist?(full)
  end

  def initialize(kind:, language:, count:, service:, out:)
    raise ArgumentError, "#{kind.key} plants no key" unless kind.planted_key?

    @kind     = kind
    @language = language
    @count    = count
    @service  = service
    @out      = out
    @user     = User.new(skill_level: KindDifficulty::LEVELS.last)
  end

  def plan
    @out.puts "=== draft_key_samples plan: #{@kind.key}, #{@language} · #{@count} sections · no provider call made ==="
    @out.puts "at most #{attempts} drafts, each judged: at most #{attempts * 2} calls"
    @out.puts "upper bound, with every call at its output cap and no caching: $#{format('%.2f', upper_bound_cost)}"
  end

  def call
    tally = { entries: [], rejected: 0, keyless: 0, failed: [] }
    attempts.times do |index|
      break if tally[:entries].size >= @count

      draft_one(index, tally)
    end
    Result.new(**tally)
  end

  def write(result, path)
    File.write(path, JSON.pretty_generate("sections" => result.entries, "rejected" => result.rejected,
                                          "keyless" => result.keyless, "failed" => result.failed))
  end

  def cost_line(usage)
    return "#{usage.sum { |call| call[:tokens_in] }} in / #{usage.sum { |call| call[:tokens_out] }} out · unpriced" if usage.empty?

    total = usage.sum do |call|
      ClaudeService.cost_usd(model: route_for(call[:purpose])[:model], input_tokens: call[:tokens_in], output_tokens: call[:tokens_out],
                             cache_read_tokens: call[:cache_read], cache_write_tokens: call[:cache_write]).to_f
    end
    "#{usage.size} calls · #{usage.sum { |call| call[:tokens_in] }} in / #{usage.sum { |call| call[:tokens_out] }} out · $#{format('%.2f', total)}"
  end

  private

  def attempts = @count * ATTEMPTS_PER_SECTION

  def rung_at(index) = KindDifficulty::LEVELS[index % KindDifficulty::LEVELS.size]

  def concept_at(index)
    concepts = self.class.concepts_for(@kind, @language, rung_at(index))
    concepts[index % concepts.size]
  end

  def draft_one(index, tally)
    rung, concept = rung_at(index), concept_at(index)
    section = @service.send(:retry_section, draft_for(rung), @kind, concept)
    return tally[:keyless] += 1 unless section&.key?(PlantedKey::FIELD)

    verdict = @service.judge_section(@user, @kind, section, rung: rung, locked: true)
    return tally[:rejected] += 1 if verdict.reject?

    tally[:entries] << entry(verdict.apply(section), rung, verdict)
  rescue ProviderError, SetupError, JudgeVerdict::Invalid => e
    tally[:failed] << "#{e.class}: #{e.message}"
  end

  def entry(section, rung, verdict)
    KeySheetExport.entry(@kind.key, @language, section).merge("concept" => section["concept"], "rung" => rung,
                                                               "judge" => verdict.status.to_s)
  end

  def draft_for(rung)
    plan       = DailyPlan.for(@user, language: @language)
    difficulty = KindDifficulty.new(levels: { @kind.key => rung }, locked: [ @kind.key ])
    ExerciseDraft::Draft.new(user: @user, language: @language, problem_set: {}, plan: plan, kinds: plan.kinds,
                             difficulty: difficulty, ladders: {}, history: [], suggested_concepts: [], unusable_sections: [])
  end

  def upper_bound_cost
    rung   = rung_at(0)
    draft  = draft_for(rung)
    prompt = @service.send(:generation_prompt, @user, @language, plan: draft.plan, history: [], difficulty: draft.difficulty, ladders: {})
    draft_in = tokens(@service.send(:build_system_prompt, @language), prompt.render(only: @kind, fixed_concept: concept_at(0)))
    judge    = SectionJudgePrompt.generate(kind: @kind, section: FakeService::EXERCISE_PROBLEM_SET.fetch(@kind.key), rung: rung, locked: true)
    judge_in = tokens(judge[:system], judge[:prompt], judge[:response_schema].to_json)

    attempts * (call_cost("retry_section", draft_in) + call_cost("judge_section", judge_in))
  end

  def tokens(*texts) = texts.sum(&:size) / APPROX_CHARS_PER_TOKEN

  def call_cost(purpose, input)
    cap = CallProfiles.fetch(purpose)[:max_tokens] || ClaudeService::MAX_TOKENS
    ClaudeService.cost_usd(model: route_for(purpose)[:model], input_tokens: input, output_tokens: cap,
                           cache_read_tokens: 0, cache_write_tokens: 0).to_f
  end

  def route_for(purpose) = ClaudeService::MODEL_FOR_PURPOSE.fetch(purpose, ClaudeService::DEFAULT_ROUTE)
end
