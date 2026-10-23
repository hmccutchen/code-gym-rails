require "rails_helper"

RSpec.describe JudgedGeneration::SolveChain do
  let(:kind) { ExerciseSection::DesignComparison }
  let(:section) { { "concept" => "open_closed", "piece_a" => "a", "piece_b" => "b", "answer_key" => { "better" => "b" } } }
  let(:pass) { { judge_provider: "anthropic", judge_model: "judge-model" } }
  let(:chain) { described_class.new(kind, rung: "senior", locked: false) }

  def judge(attempt, status = "keep")
    chain.record(section, JudgeVerdict.new(status: status.to_sym, solve: "b"), true, pass, attempt: attempt)
  end

  def visibility(dropped: false) = chain.solves(dropped: dropped).map { |solve| [ solve.shipped, solve.never_shown_reason ] }

  it "gives a chain nothing settled and nothing dropped no reason, so its rows stay hidden until review" do
    judge(0, "reject")
    judge(1)

    expect(visibility).to eq([ [ false, nil ], [ false, nil ] ])
  end

  it "calls a section dropped only when the run dropped it, whatever was settled" do
    judge(0)
    chain.settle(0)

    expect(visibility(dropped: true)).to eq([ [ false, "section_dropped" ] ])
  end

  it "marks only attempts before the settled one as replaced" do
    judge(0, "reject")
    judge(1)
    chain.settle(1)

    expect(visibility).to eq([ [ false, "replaced_by_retry" ], [ true, nil ] ])
  end

  it "refuses to settle twice" do
    chain.settle(0)

    expect { chain.settle(1) }.to raise_error(described_class::AlreadySettled, /design_comparison settled at 0, then at 1/)
  end

  it "records nothing for a kind the judge does not solve" do
    plain = described_class.new(ExerciseSection::CodeReview, rung: "senior", locked: false)
    plain.record({ "concept" => "n_plus_one" }, JudgeVerdict.new(status: :keep), nil, pass, attempt: 0)

    expect(plain.solves(dropped: false)).to eq([])
  end
end
