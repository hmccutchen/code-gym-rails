require "rails_helper"

# Specced against plain callables rather than a provider subclass: the pipeline
# reaches a provider only through JudgedGeneration::Provider, so these examples
# pin that interface as well as the keep, retry, drop and fallback rules.
RSpec.describe JudgedGeneration do
  let(:draft_type) { Struct.new(:problem_set, :plan, :kinds, :difficulty, keyword_init: true) }
  let(:plan_type) { Struct.new(:due_checks, :fourth_due_checks, :reinforcement, :fourth_reinforcement, keyword_init: true) }
  let(:due_check) { Struct.new(:concept) }

  let(:user) { User.new(id: 42, skill_level: "solid") }
  let(:kinds) { [ ExerciseSection::CodeReview, ExerciseSection::Pattern, ExerciseSection::Challenge ] }
  let(:drafted) do
    {
      "code_review" => { "concept" => "n_plus_one", "question" => "What is wrong?", "snippet" => "code" },
      "pattern"     => { "concept" => "service_objects", "question" => "Which pattern?" },
      "challenge"   => { "concept" => "memoization", "question" => "Implement it" },
      "architecture" => { "concept" => "extra", "question" => "never planned" }
    }
  end
  let(:plan) do
    plan_type.new(due_checks: [ due_check.new("service_objects") ], fourth_due_checks: [],
                  reinforcement: [ { concept: "memoization" } ], fourth_reinforcement: nil)
  end
  let(:draft) { draft_type.new(problem_set: drafted, plan: plan, kinds: kinds, difficulty: KindDifficulty.none) }
  let(:finished) { [] }
  let(:finish) { ->(set, **logs) { finished << [ set, logs ] } }
  let(:judged_calls) { [] }
  let(:retry_calls) { [] }
  let(:verdicts) { Hash.new { |hash, key| hash[key] = [ { "status" => "keep" } ] } }
  let(:retried_sections) { {} }

  let(:providers) do
    lambda do
      JudgedGeneration::Provider.new(
        judge_section: lambda { |judged_user, kind, section, rung:, locked:|
          judged_calls << [ judged_user, kind.key, section, rung, locked ]
          reply = verdicts[kind.key].length > 1 ? verdicts[kind.key].shift : verdicts[kind.key].first
          raise reply if reply.is_a?(Exception)

          JudgeVerdict.parse(reply, kind: kind)
        },
        retry_section: lambda { |retry_user, language, retry_draft, kind, concept|
          retry_calls << [ retry_user, language, retry_draft, kind.key, concept ]
          reply = retried_sections.fetch(kind.key) { drafted[kind.key].merge("question" => "Retried") }
          raise reply if reply.is_a?(Exception)

          reply
        }
      )
    end
  end

  def reject(principle = "scope_mismatch")
    { "status" => "reject", "principle" => principle, "evidence" => "quoted", "reason" => "because" }
  end

  def run = described_class.call(user: user, language: "ruby_rails", draft: draft, providers: providers, finish: finish)

  it "judges only planned sections, at each kind's rung, and returns the existing JudgedSet" do
    judged = run

    expect(judged).to be_a(AiService::JudgedSet)
    expect(judged.problem_set.keys).to eq(%w[code_review pattern challenge])
    expect(judged.dropped_sections).to eq([])
    expect(judged.outcomes.values).to all(include(status: :keep, retries: 0, dropped: false, fallback: nil))
    expect(judged_calls.map { |call| call[1] }).to contain_exactly("code_review", "pattern", "challenge")
    expect(judged_calls).to all(satisfy { |call| call[0] == user && call[3] == "senior" && call[4] == false })
    expect(retry_calls).to be_empty
  end

  it "retries a rejection once through the provider with the draft's kind and concept" do
    verdicts["pattern"] = [ reject, { "status" => "keep" } ]

    judged = run

    expect(retry_calls).to eq([ [ user, "ruby_rails", draft, "pattern", "service_objects" ] ])
    expect(judged.problem_set["pattern"]["question"]).to eq("Retried")
    expect(judged.outcomes["pattern"]).to include(status: :keep, retries: 1, principle: "scope_mismatch",
                                                  retry_principle: nil)
  end

  it "drops a droppable section rejected twice and hands the finish step what it carried" do
    verdicts["pattern"] = [ reject, reject("underdetermined") ]

    judged = run

    expect(judged.dropped_sections).to eq([ "pattern" ])
    expect(judged.problem_set).not_to have_key("pattern")
    expect(judged.outcomes["pattern"]).to include(status: :reject, dropped: true, retry_principle: "underdetermined")
    set, logs = finished.sole
    expect(set).to equal(judged.problem_set)
    expect(logs).to eq(
      dropped_concepts: { "pattern" => "service_objects" }, judge: judged.outcomes,
      unhosted: [ { section: "pattern", concept: "service_objects", planned_as: "retention" } ]
    )
  end

  it "anchors a twice-rejected code_review instead of dropping it" do
    verdicts["code_review"] = [ reject ]

    judged = run

    expect(judged.problem_set["code_review"]).to include("anchored" => true, "question" => "Retried")
    expect(judged.outcomes["code_review"]).to include(dropped: false, fallback: "anchor", retries: 1)
  end

  it "drops without a retry call when the drafted concept is other" do
    drafted["challenge"]["concept"] = "other"
    verdicts["challenge"] = [ reject ]

    judged = run

    expect(retry_calls).to be_empty
    expect(judged.dropped_sections).to eq([ "challenge" ])
    expect(finished.sole.last[:unhosted]).to eq([])
  end

  it "drops a section whose retry fails, logging it instead of raising" do
    verdicts["challenge"] = [ reject ]
    retried_sections["challenge"] = AiService::RateLimitError.new("slow down")
    allow(Rails.logger).to receive(:warn)

    judged = run

    expect(judged.dropped_sections).to eq([ "challenge" ])
    expect(judged.outcomes["challenge"]).to include(retries: 0, dropped: true)
    expect(Rails.logger).to have_received(:warn).with(/\[judge_retry_failed\] user=42 section=challenge/)
  end

  it "keeps the draft and records the reason when the judge cannot answer" do
    verdicts["code_review"] = [ AiService::TimeoutError.new("slow") ]
    verdicts["pattern"]     = [ JudgeVerdict::Invalid.new("bad") ]
    verdicts["challenge"]   = [ AiService::RateLimitError.new("busy") ]
    allow(Rails.logger).to receive(:warn)

    judged = run

    expect(judged.problem_set.slice("code_review", "pattern", "challenge")).to eq(drafted.except("architecture"))
    expect(judged.outcomes.transform_values { |outcome| outcome[:fallback] })
      .to eq("code_review" => "timeout", "pattern" => "invalid_output", "challenge" => "rate_limit")
    expect(Rails.logger).to have_received(:warn).with(/\[judge_fallback\]/).exactly(3).times
  end

  it "asks the factory for a fresh provider for every judge and retry call" do
    verdicts["pattern"] = [ reject, { "status" => "keep" } ]
    built = 0
    counting = -> { built += 1; providers.call }

    described_class.call(user: user, language: "ruby_rails", draft: draft, providers: counting, finish: finish)

    expect(built).to eq(kinds.size + 2)
  end

  it "leaves the draft's own problem set untouched" do
    verdicts["pattern"] = [ reject, reject ]

    expect { run }.not_to change { drafted.deep_dup }
  end
end
