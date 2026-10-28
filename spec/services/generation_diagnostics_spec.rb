require "rails_helper"

RSpec.describe GenerationDiagnostics do
  let(:user) { User.create!(email: "diagnostics@example.com", name: "Diagnostics") }
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
                             difficulty: KindDifficulty.none, ladders: {}, history: [], suggested_concepts: [], unusable_sections: [])
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
      diagnostics.key_notes([ ProblemSetIngest::KeyNote.new(key: "code_review", language: "ruby_rails", outcome: "quote_missing") ])
      diagnostics.finished("ruby_rails", draft, problem_set, dropped_concepts: { "challenge" => "caching" })
    end

    expect(lines.map { |line| line[/\A\[\w+\]/] }.uniq)
      .to contain_exactly("[set_size]", "[unusable_section]", "[planted_key]", "[retention]", "[shared_concept]", "[coverage]", "[difficulty_diagnostics]")
    expect(lines).to all(satisfy { |line| line.exclude?(sentinel) })
  end

  it "logs one line per key note, with its kind, language and outcome" do
    notes = [ ProblemSetIngest::KeyNote.new(key: "code_review", language: "ruby_rails", outcome: "ok"),
              ProblemSetIngest::KeyNote.new(key: "plan_review", language: "javascript", outcome: "missing") ]

    lines = logged_lines { described_class.new(user).key_notes(notes) }

    expect(lines).to eq([ "[planted_key] answer_key=ok kind=code_review language=ruby_rails user=#{user.id}",
                          "[planted_key] answer_key=missing kind=plan_review language=javascript user=#{user.id}" ])
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
                                         dropped_concepts: { "challenge" => "caching", "plan_review" => "rollout_plan" })
    end

    retention = lines.grep(/\A\[retention\].*offered=/)
    expect(retention.find { |line| line.include?("bucket=ruby_rails") }).to include("dropped=challenge:caching")
    expect(retention.find { |line| line.include?("bucket=#{DailyPlan::FOURTH_BUCKET_FOR.fetch(:plan_review)}") })
      .to include("dropped=plan_review:rollout_plan")
  end
end
