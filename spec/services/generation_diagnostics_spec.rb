require "rails_helper"

RSpec.describe GenerationDiagnostics do
  let(:user) { User.create!(email: "diagnostics@example.com") }
  let(:sentinel) { "ANSWER-KEY-SENTINEL" }
  let(:rotation) { { pattern: :pattern, third: :challenge, fourth: :plan_review } }
  let(:kinds) { ExerciseSection.for_plan(daily: DailyKinds::DEFAULT, rotation: rotation) }
  let(:size) { Struct.new(:diagnostics, :count, :reason).new({ count: kinds.size }, kinds.size, "automatic") }
  let(:due) { Struct.new(:concept) }
  let(:plan) do
    plan_for(**rotation, due_checks: [ due.new("caching") ], fourth_due_checks: [ due.new("rollout_plan") ],
             shared_concept: "caching", waiting_checks: [ { bucket: "ruby_rails", concept: "memoization", reason: "rested" } ],
             coverage: Struct.new(:kind, :reason).new(ExerciseSection::Challenge, "gap"), size: size)
  end
  let(:draft) do
    ExerciseDraft::Draft.new(user: user, language: "ruby_rails", problem_set: {}, plan: plan, kinds: kinds,
                             difficulty: KindDifficulty.none, ladders: {}, history: [], delivered_history: [], suggested_concepts: [], unusable_sections: [])
  end

  # Every section carries every answer-key field any kind declares, so a new kind or a new field is covered unchanged.
  let(:problem_set) do
    kinds.to_h do |kind|
      [ kind.key, { "question" => "visible text", "concept" => "caching" }
                    .merge(ExerciseSection.all_answer_key_fields.index_with { sentinel }) ]
    end
  end

  def logged_lines
    lines = []
    %i[info warn].each { |level| allow(Rails.logger).to receive(level) { |message| lines << message.to_s } }
    yield
    lines
  end

  it "writes every generation log line without an answer-key value in any of them" do
    lines = logged_lines do
      diagnostics = described_class.new(user)
      diagnostics.set_size(size)
      diagnostics.unusable_sections([ Struct.new(:key, :reason).new("pattern", "too short") ])
      diagnostics.key_notes([ ProblemSetIngest::KeyNote.new(key: "code_review", language: "ruby_rails", outcome: "quote_missing", quotes: nil) ],
                            attempt: "draft", code_review_mode: :application_code, code_review_files: 1..1)
      diagnostics.finished("ruby_rails", draft, problem_set, dropped_concepts: { "challenge" => "caching" }, judge: nil, unhosted: [])
    end

    expect(lines.map { |line| line[/\A\[\w+\]/] }.uniq)
      .to contain_exactly("[set_size]", "[unusable_section]", "[planted_key]", "[retention]", "[shared_concept]", "[coverage]", "[difficulty_diagnostics]")
    expect(lines).to all(satisfy { |line| line.exclude?(sentinel) })
  end

  it "logs only assessed performance, without pending ratings or delivered repetition notes" do
    exercise = user.daily_exercises.create!(date: Date.yesterday, generated_at: Time.current, language: "ruby_rails",
      problem_set: { "code_review" => { "concept" => "caching", "scenario" => "REPETITION-ONLY" },
                     "pattern" => { "concept" => "memoization" } })
    user.daily_responses.create!(daily_exercise: exercise, date: exercise.date, submitted_at: Time.current,
      answers: { "code_review" => "Bound the cache", "pattern" => "Pending answer" },
      concept_tags: { "code_review" => "caching", "pattern" => "memoization" },
      section_ratings: { "code_review" => "UNRECOGNIZED", "pattern" => "too_hard" },
      ai_review: { "code_review" => { "rating" => "solid" } })
    captured = draft.with(history: user.recent_performance, delivered_history: user.recent_delivered_content)
    lines = logged_lines do
      described_class.new(user).finished("ruby_rails", captured, problem_set, dropped_concepts: {}, judge: nil, unhosted: [])
    end
    payload = JSON.parse(lines.grep(/\A\[difficulty_diagnostics\]/).sole.delete_prefix("[difficulty_diagnostics] "))
    history = payload.fetch("requested").fetch("recent_performance")

    expect(history).to eq([ { "date" => exercise.date.to_s, "completion" => nil,
                             "sections" => [ { "key" => "code_review", "concept" => "caching", "ai_rating" => "solid" } ] } ])
    expect(lines.join).not_to include("REPETITION-ONLY", "UNRECOGNIZED", "Pending answer")
  end

  it "logs one line per key note, with its kind, language and outcome" do
    notes = [ ProblemSetIngest::KeyNote.new(key: "code_review", language: "ruby_rails", outcome: "ok", quotes: nil),
              ProblemSetIngest::KeyNote.new(key: "plan_review", language: "javascript", outcome: "missing", quotes: nil) ]

    lines = logged_lines { described_class.new(user).key_notes(notes, attempt: "draft", code_review_mode: :test_file, code_review_files: 1..1) }

    expect(lines).to eq([ "[planted_key] answer_key=ok kind=code_review language=ruby_rails attempt=draft code_review_mode=test_file " \
                          "code_review_files=single user=#{user.id}",
                          "[planted_key] answer_key=missing kind=plan_review language=javascript attempt=draft code_review_mode=test_file " \
                          "code_review_files=single user=#{user.id}" ])
  end

  it "marks a day that asked for several files as multi" do
    note = ProblemSetIngest::KeyNote.new(key: "code_review", language: "ruby_rails", outcome: "evidence_unlocated", quotes: nil)

    lines = logged_lines { described_class.new(user).key_notes([ note ], attempt: "draft", code_review_mode: :test_file, code_review_files: 2..3) }

    expect(lines.sole).to include("answer_key=evidence_unlocated", "code_review_files=multi")
  end

  it "keeps the judge's pick, the answer key and the solves out of the payload a judged generation logs" do
    judged = nil
    lines = logged_lines { judged = FakeService.new("fake-key").generate_judged_exercise(user, language: "ruby_rails") }

    payload = lines.grep(/\A\[difficulty_diagnostics\]/).sole
    key = judged.problem_set.fetch("design_comparison").fetch("answer_key")
    expect(judged.solves).not_to be_empty
    expect(payload).to include("solve_matched")
    expect(payload).not_to include("answer_key", "\"better\"", "judge_pick", "judged_section", "solves", "Solve",
                                   key.fetch("deciding_fact"), key.fetch("why_other_fails"))
  end

  it "reports each dropped concept on its own track's retention line" do
    lines = logged_lines do
      described_class.new(user).finished("ruby_rails", draft, problem_set,
                                         dropped_concepts: { "challenge" => "caching", "plan_review" => "rollout_plan" }, judge: nil, unhosted: [])
    end

    retention = lines.grep(/\A\[retention\].*offered=/)
    expect(retention.find { |line| line.include?("bucket=ruby_rails") }).to include("dropped=challenge:caching")
    expect(retention.find { |line| line.include?("bucket=#{DailyPlan::FOURTH_BUCKET_FOR.fetch(:plan_review)}") })
      .to include("dropped=plan_review:rollout_plan")
  end

  describe "a retention check held back by the featured concept" do
    def waiting_line(check, featured_concept: "scope_creep")
      check = { bucket: "plan_review", concept: "scope_creep", reason: :no_host }.merge(check)
      held  = draft.with(plan: plan.with(featured_concept: featured_concept, waiting_checks: [ check ]))
      lines = logged_lines { described_class.new(user).finished("ruby_rails", held, problem_set, dropped_concepts: {}, judge: nil, unhosted: []) }
      lines.grep(/\A\[retention\].*waiting=/).sole
    end

    it "names the featured concept when the plan marked a check it held back" do
      expect(waiting_line({ held_by_featured: true }))
        .to eq("[retention] user=#{user.id} date=#{Date.current} waiting=plan_review:scope_creep(no_host) featured=scope_creep")
    end

    it "names no featured concept when the plan marked nothing, even for a no_host check on that concept" do
      expect(waiting_line({})).not_to include("featured=")
      expect(waiting_line({ reason: :no_slot })).not_to include("featured=")
    end
  end
end
