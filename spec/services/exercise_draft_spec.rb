require "rails_helper"

RSpec.describe ExerciseDraft do
  include MetConceptHelpers

  let(:user) { User.create!(email: "draft@example.com", skill_level: "senior") }
  let(:generated) { [] }
  let(:rendered) { [] }
  let(:prompt) do
    Struct.new(:rendered) do
      def render(only: nil, fixed_concept: nil, retry_cause: nil)
        rendered << { only: only&.key, fixed_concept: fixed_concept }.merge(retry_cause ? { retry_cause: retry_cause } : {})
        "rendered prompt"
      end
    end.new(rendered)
  end
  let(:reply) { FakeService::EXERCISE_PROBLEM_SET.deep_dup }
  let(:recorded) { [] }
  let(:provider) do
    described_class::Provider.new(
      prompt: ->(*, **) { prompt },
      generate: lambda { |generating_user, purpose, language, text, **options|
        generated << { user: generating_user, purpose: purpose, language: language, prompt: text, **options }
        reply
      },
      record_suggestion: ->(suggestion) { recorded << suggestion.name }
    )
  end

  def draft_for(language: "ruby_rails", mode: :application_code)
    described_class::Draft.new(user: user, skill_level: user.skill_level, language: language, problem_set: {}, plan: plan_for(code_review_mode: mode),
                               kinds: [], difficulty: KindDifficulty.none, kind_rungs: KindDifficulty.none.rungs(skill_level: user.skill_level), ladders: {}, history: [], delivered_history: [],
                               suggested_concepts: [], unusable_sections: [])
  end

  it "keeps the draft to its user and language, the plan, the drafted inputs and the ingest results" do
    expect(described_class::Draft.members)
      .to eq(%i[user skill_level language problem_set plan kinds difficulty kind_rungs ladders history delivered_history suggested_concepts unusable_sections schedule_context adjustments])
  end

  it "asks for the week's featured concept and plans the day around it, so a hiding kind is never offered it" do
    featured = ConceptVocabulary::PLAN_REVIEW_CONCEPTS.first
    allow(FeaturedConcept).to receive(:for).with(user).and_return(FeaturedConcept.new(concept: featured, bucket: "plan_review"))
    allow(DailyPlan).to receive(:for).and_call_original

    draft = described_class.call(user, language: "ruby_rails", provider: provider)

    expect(DailyPlan).to have_received(:for).with(user, language: "ruby_rails", featured_concept: featured, schedule_context: nil)
    expect(draft.plan.featured_concept).to eq(featured)
  end

  it "never gives a bug_hunt section the concept the week features, using the real weekly pick" do
    first = BugHuntGotchas.for_language("ruby_rails").first
    submit_set_showing(user, first.concept, date: Date.current - 2)
    pin_code_review_mode(:bug_hunt)

    draft = described_class.call(user, language: "ruby_rails", provider: provider)

    expect(FeaturedConcept.for(user)&.concept).to eq(first.concept)
    expect(draft.plan.featured_concept).to eq(first.concept)
    expect(draft.plan.code_review_gotcha.concept).not_to eq(first.concept)
  end

  it "plans with no featured concept when the user has none yet" do
    allow(FeaturedConcept).to receive(:for).with(user).and_return(nil)

    expect(described_class.call(user, language: "ruby_rails", provider: provider).plan.featured_concept).to be_nil
  end

  it "generates with no featured concept, and logs, when the weekly lookup raises a database error" do
    allow(FeaturedConcept).to receive(:for).with(user).and_raise(ActiveRecord::StatementInvalid, "boom")
    allow(Rails.logger).to receive(:warn)

    draft = described_class.call(user, language: "ruby_rails", provider: provider)

    expect(draft.plan.featured_concept).to be_nil
    expect(Rails.logger).to have_received(:warn).with(/featured concept.*user #{user.id}/i)
  end

  it "takes the provider calls as callables and the draft as its only retry context" do
    expect(described_class::Provider.members).to eq(%i[prompt generate record_suggestion])
    expect(described_class.method(:retry_section).parameters)
      .to eq([ %i[req draft], %i[req kind], %i[req concept], %i[keyreq provider], %i[key cause], %i[key deadline] ])
  end

  it "drafts with no timeout of its own: only the user, language, provider and deadline" do
    expect(described_class.method(:call).parameters).to eq([ %i[req user], %i[keyreq language], %i[keyreq provider], %i[key deadline], %i[key schedule_context] ])
  end

  it "uses the captured work date if planning crosses midnight" do
    context = nil
    travel_to(Time.utc(2026, 11, 6, 23, 59)) { context = PracticeGeneration.capture(user, date: Date.current) }
    allow(DailyPlan).to receive(:size_for).and_call_original
    allow(WeightedRoll).to receive(:pick).and_call_original
    expect(WeightedRoll).to receive(:pick).with(DailyPlan::CODE_REVIEW_MODE_WEIGHTS).and_return(:application_code)
    travel_to(Time.utc(2026, 11, 7, 0, 1)) do
      described_class.call(user, language: "ruby_rails", provider: provider, schedule_context: context)
    end
    expect(DailyPlan).to have_received(:size_for).with(user, before: Date.new(2026, 11, 6))
  end

  it "finishes only with every log the judged path hands it" do
    logs = [ %i[keyreq dropped_concepts], %i[keyreq judge], %i[keyreq unhosted] ]

    expect(described_class.method(:finish).parameters).to include(*logs)
    expect(GenerationDiagnostics.instance_method(:finished).parameters).to include(*logs)
  end

  it "drafts the day through one generate_exercise call and returns the ingested set" do
    deadline = GenerationDeadline.new(1.hour.from_now)

    draft = described_class.call(user, language: "ruby_rails", provider: provider, deadline: deadline)

    expect(generated).to eq([ { user: user, purpose: "generate_exercise", language: "ruby_rails", prompt: "rendered prompt",
                                subject: "problem set", deadline: deadline } ])
    expect(rendered).to eq([ { only: nil, fixed_concept: nil } ])
    expect(draft).to have_attributes(user: user, language: "ruby_rails")
    expect(draft.problem_set.keys).to match_array(draft.kinds.map(&:key))
  end

  it "captures both histories once and reuses the same projections on retry" do
    inputs = []
    capturing = provider.with(prompt: ->(*, **options) { inputs << options; prompt })
    expect(user).to receive(:recent_performance).once.and_call_original
    expect(user).to receive(:recent_delivered_content).once.and_call_original
    draft = described_class.call(user, language: "ruby_rails", provider: capturing)
    described_class.retry_section(draft, ExerciseSection::CodeReview, "n_plus_one", provider: capturing)

    expect(inputs.size).to eq(2)
    expect(inputs.last[:history]).to equal(inputs.first[:history])
    expect(inputs.last[:delivered_history]).to equal(inputs.first[:delivered_history])
  end

  it "captures all server rungs before the call and reuses them when retrying" do
    original = KindDifficulty.for(user).rungs(skill_level: user.skill_level)
    reply["kind_rungs"] = { "code_review" => "principal_engineer" }
    reply["code_review"]["pitched_at"] = "principal_engineer"
    changing = provider.with(generate: ->(*, **) { user.skill_level = "junior"; reply })
    draft = described_class.call(user, language: "ruby_rails", provider: changing)
    expect(draft.kind_rungs).to eq(original)
    expect(draft.problem_set["code_review"]["pitched_at"]).to eq("senior")
    reply["code_review"]["pitched_at"] = "principal_engineer"
    retried = described_class.retry_section(draft, ExerciseSection::CodeReview, "n_plus_one", provider: provider)
    expect(retried["pitched_at"]).to eq("senior")
    expect(draft.plan.notes(kind_rungs: draft.kind_rungs)["kind_rungs"]).to eq(original)
  end

  it "removes bug performance from initial and retry prompts while retaining repetition context" do
    exercise = user.daily_exercises.create!(date: Date.yesterday, generated_at: Time.current,
      problem_set: { "code_review" => { "purpose" => "Find the trap", "concept" => "memoization", "scenario" => "BUG-REPETITION" },
        "pattern" => { "question" => "q", "concept" => "caching" } })
    user.daily_responses.create!(date: exercise.date, daily_exercise: exercise, submitted_at: Time.current,
      answers: { "code_review" => "bug answer", "pattern" => "core answer" },
      section_ratings: { "code_review" => "too_hard", "pattern" => "right_level" },
      ai_review: { "code_review" => { "rating" => "developing" }, "pattern" => { "rating" => "solid" } })
    real_prompts = provider.with(prompt: ->(person, language, **options) {
      GenerationPrompt.new(person, language, **options, retention_annotation: generation_retention_annotation)
    })
    captured = described_class.call(user, language: "ruby_rails", provider: real_prompts)
    described_class.retry_section(captured, ExerciseSection::CodeReview, "n_plus_one", provider: real_prompts)
    expect(captured.history.sole[:completion]).to eq(answered: 1, total: 1, skipped_sections: [])
    expect(captured.history.sole[:sections].map { |section| section[:key] }).to eq([ "pattern" ])
    generated.each do |request|
      evidence = request[:prompt].split("Reviewed answer evidence:").last.split("Delivered content").first
      expect(evidence).to include("1/1 answered", "pattern")
      expect(evidence).not_to include("code_review", "too_hard", "developing", "bug answer")
      expect(request[:prompt]).to include("BUG-REPETITION")
    end
  end

    it "keeps real retry instructions and multi-file schema on the captured level after the caller changes" do
      allow(WeightedRoll).to receive(:pick).with(DailyPlan::CODE_REVIEW_FILE_WEIGHTS).and_return(:multi)
      reply["code_review"] = FakeService::MULTI_FILE_CODE_REVIEW.deep_dup
      ranges = []
      allow(ProblemSetIngest).to receive(:call).and_wrap_original do |original, *args, **options|
        ranges << options.fetch(:code_review_files)
        original.call(*args, **options)
      end
      capturing = provider.with(
        prompt: ->(person, language, **options) {
          GenerationPrompt.new(person, language, **options, retention_annotation: generation_retention_annotation)
        },
        generate: ->(*args, **options) {
          provider.generate.call(*args, **options).tap { user.skill_level = "junior" }
        })
      captured = described_class.call(user, language: "ruby_rails", provider: capturing)
      retried = described_class.retry_section(captured, ExerciseSection::CodeReview, "n_plus_one", provider: capturing)

      aggregate_failures do
        generated.each do |request|
          expect(request[:prompt]).to include("Sections at senior:", "- Skill level: senior", '"file_1_path"')
          expect(request[:prompt]).not_to include("Sections at junior:", "- Skill level: junior")
        end
        expect(ranges).to eq([ 2..3, 2..3 ])
        expect(retried["pitched_at"]).to eq(captured.kind_rungs.fetch("code_review"))
      end
    end

  def planted_key_lines
    lines = []
    allow(Rails.logger).to receive(:info) { |message| lines << message.to_s if message.to_s.start_with?("[planted_key]") }
    yield
    lines
  end

  it "logs a key note for each keyed section of the drafted day" do
    draft = nil
    lines = planted_key_lines { draft = described_class.call(user, language: "ruby_rails", provider: provider) }

    keyed = draft.problem_set.keys.select { |key| ExerciseSection.find(key).planted_key? }
    expect(keyed).not_to be_empty
    expect(lines.map { |line| line[/kind=(\w+)/, 1] }).to match_array(keyed)
    expect(lines).to all(include("attempt=draft", "code_review_files=single"))
  end

  it "logs the key note of a retried section, and still returns only the section" do
    draft = described_class.call(user, language: "ruby_rails", provider: provider)

    section = nil
    lines = planted_key_lines { section = described_class.retry_section(draft, ExerciseSection::CodeReview, "n_plus_one", provider: provider) }

    expect(lines.sole).to start_with("[planted_key] answer_key=ok kind=code_review language=ruby_rails attempt=retry code_review_mode=")
    expect(section).to include("answer_key", "snippet")
  end

  it "checks a retried migration section's key against the schema the server stamps" do
    draft = described_class.call(user, language: "ruby_rails", provider: provider)
    migration = instance_double(RealSource::Migration, scenario: "s", id: "db/migrate/1_add_owner.rb",
                                                       current_schema: %(create_table "things" do |t|\n  t.bigint "owner_id"\nend\n))
    draft = draft.with(plan: draft.plan.with(code_review_source: migration, code_review_mode: :schema_review))
    reply.replace("code_review" => FakeService::EXERCISE_PROBLEM_SET["code_review"].deep_dup.merge(
      "snippet" => "add_column :things, :owner_id, :bigint",
      "answer_key" => { "issue" => '`t.bigint "owner_id"` has no index', "why_it_matters" => "w", "fix" => "f" }
    ))

    lines = planted_key_lines { described_class.retry_section(draft, ExerciseSection::CodeReview, "n_plus_one", provider: provider) }

    expect(lines.sole).to start_with("[planted_key] answer_key=ok kind=code_review language=ruby_rails attempt=retry code_review_mode=schema_review " \
                                     "code_review_files=single")
  end

  it "hands ingest the day's code_review mode, on the draft and on a retry" do
    modes = []
    allow(ProblemSetIngest).to receive(:call).and_wrap_original do |original, *args, **options|
      modes << options.fetch(:code_review_mode)
      original.call(*args, **options)
    end
    pin_code_review_mode(:test_file)

    draft = described_class.call(user, language: "ruby_rails", provider: provider)
    described_class.retry_section(draft, ExerciseSection::CodeReview, draft.problem_set.dig("code_review", "concept"), provider: provider)

    expect(modes).to eq(%i[test_file test_file])
  end

  describe "the planned code_review file range" do
    let(:ranges) { [] }

    before do
      allow(WeightedRoll).to receive(:pick).with(DailyPlan::CODE_REVIEW_FILE_WEIGHTS).and_return(:multi)
      allow(ProblemSetIngest).to receive(:call).and_wrap_original do |original, *args, **options|
        ranges << options.fetch(:code_review_files)
        original.call(*args, **options)
      end
      user.update!(skill_level: "mid_level")
    end

    it "holds the draft to the range its rung gives a multi-file day" do
      described_class.call(user, language: "ruby_rails", provider: provider)

      expect(ranges).to eq([ 2..2 ])
    end

    it "holds a retry to the same range as its draft" do
      user.update!(section_kind_levels: { "code_review" => "senior" })
      draft = described_class.call(user, language: "ruby_rails", provider: provider)
      reply.replace("code_review" => FakeService::MULTI_FILE_CODE_REVIEW.deep_dup)

      section = described_class.retry_section(draft, ExerciseSection::CodeReview, "n_plus_one", provider: provider)

      expect(ranges).to eq([ 2..3, 2..3 ])
      expect(ExerciseSection::CodeReview.files(section).size).to eq(2)
    end
  end

  it "refuses an unsupported language before it plans or calls" do
    expect { described_class.call(user, language: "cobol", provider: provider) }.to raise_error(SetupError)
    expect(generated).to be_empty
  end

  it "retries one kind with its concept fixed, keeping back time for the re-judge" do
    draft = described_class.call(user, language: "ruby_rails", provider: provider)
    generated.clear
    rendered.clear
    ends_at = 1.hour.from_now
    reply.replace("pattern" => FakeService::EXERCISE_PROBLEM_SET["pattern"].deep_dup)

    section = described_class.retry_section(draft, ExerciseSection::Pattern, "service_objects",
                                            provider: provider, deadline: GenerationDeadline.new(ends_at))

    expect(rendered).to eq([ { only: "pattern", fixed_concept: "service_objects" } ])
    expect(generated.sole).to include(user: user, purpose: "retry_section", language: "ruby_rails", subject: "pattern retry")
    expect(generated.sole[:deadline].ends_at).to eq(ends_at - CallProfiles.worst_case_seconds_for("judge_section"))
    expect(section).to include("concept" => "service_objects", "pitched_at" => "senior")
  end

  it "hands the retry prompt the recorded cause of the rejection, when there is one" do
    draft = described_class.call(user, language: "ruby_rails", provider: provider)
    rendered.clear
    reply.replace("pattern" => FakeService::EXERCISE_PROBLEM_SET["pattern"].deep_dup)

    described_class.retry_section(draft, ExerciseSection::Pattern, "service_objects", cause: "scope_mismatch", provider: provider)

    expect(rendered).to eq([ { only: "pattern", fixed_concept: "service_objects", retry_cause: "scope_mismatch" } ])
  end

  it "renders a retry prompt carrying none of the rejected section's text, so the retry starts from fresh pieces" do
    real_prompt = provider.with(prompt: lambda { |*args, **options|
      GenerationPrompt.new(*args, **options, retention_annotation: ->(*) { })
    })
    draft = described_class.call(user, language: "ruby_rails", provider: real_prompt)
    rejected = draft.problem_set.fetch("design_comparison").merge(
      "piece_a" => "def rejected_piece_alpha = 1", "piece_b" => "def rejected_piece_beta = 2",
      "scenario" => "REJECTED-SCENARIO", "answer_key" => { "better" => "a", "deciding_fact" => "REJECTED-FACT" }
    )
    draft = draft.with(problem_set: draft.problem_set.merge("design_comparison" => rejected))
    generated.clear
    reply.replace("design_comparison" => FakeService::EXERCISE_PROBLEM_SET["design_comparison"].deep_dup)

    described_class.retry_section(draft, ExerciseSection::DesignComparison, rejected["concept"], provider: real_prompt)

    expect(generated.sole[:prompt]).to include(rejected["concept"])
    expect(generated.sole[:prompt]).not_to include("rejected_piece_alpha", "rejected_piece_beta", "REJECTED-SCENARIO", "REJECTED-FACT")
  end

  it "records each suggested concept through the provider when the set is finished, logging a failed one and keeping on" do
    suggestion = Struct.new(:bucket, :name)
    draft = draft_for.with(suggested_concepts: [ suggestion.new("ruby_rails", "first"), suggestion.new("ruby_rails", "second") ])
    failing = provider.with(record_suggestion: lambda { |entry|
      raise "db down" if entry.name == "first"

      recorded << entry.name
    })
    allow(GenerationDiagnostics).to receive(:new).and_return(instance_double(GenerationDiagnostics, finished: nil))
    allow(Rails.logger).to receive(:warn)

    described_class.finish(draft, {}, provider: failing, dropped_concepts: {}, judge: nil, unhosted: [])

    expect(recorded).to eq(%w[second])
    expect(Rails.logger).to have_received(:warn).with(/SuggestedConcept recording failed: db down/)
  end

  describe "retry ladders" do
    before do
      allow(ProblemSetIngest).to receive(:call).and_return(double(problem_set: {}, key_notes: []))
    end

    it "gives a one-section retry only that section's ladder rungs" do
      ConceptReference.create!(concept: "n_plus_one", language: "ruby_rails",
                               ladder_junior: "j", ladder_mid_level: "m", ladder_senior: "s", ladder_principal_engineer: "p")
      ConceptReference.create!(concept: "scope_creep", language: ConceptBucket.for("plan_review", "ruby_rails"),
                               ladder_junior: "j", ladder_mid_level: "m", ladder_senior: "s", ladder_principal_engineer: "p")
      user.update!(skill_level: "junior")

      ladders = []
      capturing = provider.with(prompt: ->(*, **options) { ladders << options.fetch(:ladders); prompt })
      described_class.retry_section(draft_for, ExerciseSection::Pattern, "n_plus_one", provider: capturing)
      described_class.retry_section(draft_for, ExerciseSection::PlanReview, "scope_creep", provider: capturing)

      expect(ladders).to eq([ { ExerciseSection::Pattern => { "n_plus_one" => "j" } },
                             { ExerciseSection::PlanReview => { "scope_creep" => "j" } } ])
    end

    it "loads a retry's ladders for the draft's language and code_review mode" do
      allow(GenerationLadders).to receive(:for).and_call_original

      described_class.retry_section(draft_for(language: "javascript", mode: :schema_review), ExerciseSection::CodeReview,
                                    "promises", provider: provider)

      expect(GenerationLadders).to have_received(:for).with(anything, "javascript", :schema_review, gotcha: nil, featured_concept: nil)
    end
  end
end
