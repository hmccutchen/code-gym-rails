require "rails_helper"

RSpec.describe JudgeSolve::Counts, type: :model do
  let(:user) { User.create!(email: "counts@example.com", name: "C") }
  let(:exercise) { exercise_on(Date.current) }
  let(:counts) { described_class.new }

  def exercise_on(date)
    DailyExercise.create!(user: user, date: date, generated_at: Time.current.change(usec: 0), language: "ruby_rails",
                          problem_set: { "design_comparison" => section("shipped") })
  end

  def section(tag) = { "title" => tag, "piece_a" => "a", "piece_b" => "b", "answer_key" => { "better" => "a" } }

  def solve!(tag = "one", on: exercise, **overrides)
    JudgeSolve.create!({ user_id: on&.user_id, daily_exercise: on, set_generated_at: on&.generated_at, source: "live",
                         section: "design_comparison", attempt: 0, edit_check: false, shipped: true, edit_reverted: false,
                         rung: "senior", locked: false, key_better: "a", judge_pick: "b", matched: false,
                         judged_section: section(tag), judge_provider: "anthropic", judge_model: "claude-test" }.merge(overrides))
  end

  def synthetic!(tag, **overrides) = solve!(tag, on: nil, source: "synthetic", **overrides)

  def review!(target = exercise)
    DailyResponse.create!(user: user, daily_exercise: target, date: target.date, submitted_at: Time.current,
                          ai_review: { "design_comparison" => { "rating" => "solid" } })
  end

  def every_outcome(counts = self.counts)
    JudgeSolve::SOURCES.product(described_class::OUTCOMES.keys).to_h { |source, name| [ [ source, name ], counts.outcome(source, name) ] }
  end

  def every_call(counts = self.counts)
    JudgeSolve::SOURCES.flat_map do |source|
      described_class::MISMATCH_CALL_ROWS.map { |call| counts.mismatch_call(source, call) } +
        described_class::MATCHED_CALL_ROWS.map { |call| counts.matched_call(source, call) } +
        JudgeSolve::REVERT_REASONS.map { |reason| counts.reverted(source, reason) }
    end
  end

  describe "visibility" do
    it "changes no outcome or call count for a hidden mismatched row, only withheld" do
      review!
      solve!("shown")
      outcomes_before = every_outcome(described_class.new)
      calls_before = every_call(described_class.new)

      solve!("hidden", on: exercise_on(Date.yesterday))
      after = described_class.new

      expect(every_outcome(after)).to eq(outcomes_before)
      expect(every_call(after)).to eq(calls_before)
      expect(outcomes_before[[ "live", "mismatched" ]]).to eq(1)
      expect(after.withheld).to eq(1)
    end

    it "counts a hidden section once, whether or not the judge edited it" do
      solve!("draft", shipped: false)
      solve!("edit", edit_check: true)
      solve!("replayed", source: "replay")
      solve!("plain", on: exercise_on(Date.yesterday))

      expect(counts.withheld).to eq(2)
    end

    it "leaves a hidden reverted edit out of the revert counts" do
      solve!("edited", edit_check: true, shipped: false, edit_reverted: true, revert_reason: "solve_mismatch")

      expect(every_call).to all(eq(0))
      expect(counts.withheld).to eq(1)
    end

    it "carries no breakdown on the withheld line" do
      solve!("hidden_live")
      solve!("hidden_replay", on: exercise_on(Date.yesterday), source: "replay", matched: true, judge_pick: "a")
      solve!("hidden_principal", on: exercise_on(Date.current - 2.days), rung: "principal_engineer")

      expect(counts.withheld).to eq(3)
      expect(described_class.public_instance_methods(false)).to contain_exactly(:outcome, :reverted, :withheld, :mismatch_call, :matched_call)
      expect(described_class.instance_method(:withheld).arity).to eq(0)
    end
  end

  describe "outcomes and reverts" do
    it "counts readable rows by source and outcome" do
      review!
      solve!("m1")
      solve!("ok", matched: true, judge_pick: "a")
      solve!("unsolved", matched: nil, judge_pick: nil)
      solve!("replay", source: "replay")
      synthetic!("syn", matched: true, judge_pick: "a")

      expect(every_outcome).to include(
        [ "live", "solved" ] => 2, [ "live", "matched" ] => 1, [ "live", "mismatched" ] => 1, [ "live", "unsolved" ] => 1,
        [ "replay", "mismatched" ] => 1, [ "replay", "solved" ] => 1, [ "synthetic", "matched" ] => 1, [ "synthetic", "mismatched" ] => 0
      )
    end

    it "counts readable reverts by source and reason" do
      review!
      solve!("r1", edit_check: true, shipped: false, edit_reverted: true, revert_reason: "solve_mismatch")
      synthetic!("r2", edit_check: true, shipped: false, edit_reverted: true, revert_reason: "judge_failed", matched: nil, judge_pick: nil)

      expect(counts.reverted("live", "solve_mismatch")).to eq(1)
      expect(counts.reverted("synthetic", "judge_failed")).to eq(1)
      expect(counts.reverted("live", "judge_failed")).to eq(0)
    end
  end

  describe "call tables" do
    before { review! }

    it "counts one call per section version, the latest call winning" do
      solve!("same", human_call: "key_right", human_called_at: 2.days.ago)
      solve!("same", source: "replay", human_call: "judge_right", human_called_at: 1.day.ago)

      expect(counts.mismatch_call("replay", "judge_right")).to eq(1)
      expect(counts.mismatch_call("live", "key_right")).to eq(0)
    end

    it "prefers a called record over an uncalled one of the same version" do
      solve!("same", human_call: "both_defensible", human_called_at: 1.day.ago)
      solve!("same", source: "replay")

      expect(counts.mismatch_call("live", "both_defensible")).to eq(1)
      expect(counts.mismatch_call("replay", "uncalled")).to eq(0)
    end

    it "keeps a version under the live row's call after a note-only save on its replay row" do
      solve!("same", human_call: "key_right", human_called_at: 1.day.ago)
      replay = solve!("same", source: "replay")

      replay.update!(human_note: "looked again")

      expect(replay.reload.human_called_at).to be_nil
      expect(counts.mismatch_call("live", "key_right")).to eq(1)
      expect(counts.mismatch_call("replay", "uncalled")).to eq(0)
    end

    it "keeps a version under the live row's call after the replay row's call is cleared" do
      solve!("same", human_call: "key_right", human_called_at: 1.day.ago)
      replay = solve!("same", source: "replay", human_call: "judge_right", human_called_at: 2.days.ago)

      replay.update!(human_call: nil)

      expect(replay.reload.human_called_at).to be_within(5.seconds).of(Time.current)
      expect(counts.mismatch_call("live", "key_right")).to eq(1)
      expect(counts.mismatch_call("replay", "uncalled")).to eq(0)
    end

    it "counts distinct versions apart" do
      solve!("one", human_call: "key_right", human_called_at: Time.current)
      solve!("two", human_call: "key_right", human_called_at: Time.current)
      solve!("three")

      expect(counts.mismatch_call("live", "key_right")).to eq(2)
      expect(counts.mismatch_call("live", "uncalled")).to eq(1)
    end

    it "leaves out unsolved and principal-engineer records" do
      solve!("unsolved", matched: nil, judge_pick: nil)
      solve!("principal", rung: "principal_engineer", human_call: "key_right", human_called_at: Time.current)
      solve!("principal_ok", rung: "principal_engineer", matched: true, judge_pick: "a")

      expect(every_call).to all(eq(0))
    end

    it "counts matched and mismatched calls apart" do
      solve!("mismatch", human_call: "key_right", human_called_at: Time.current)
      solve!("matched", matched: true, judge_pick: "a", human_call: "key_right", human_called_at: Time.current)
      solve!("wrong", matched: true, judge_pick: "a", human_call: "both_wrong", human_called_at: Time.current)

      expect(counts.mismatch_call("live", "key_right")).to eq(1)
      expect(counts.matched_call("live", "key_right")).to eq(1)
      expect(counts.matched_call("live", "both_wrong")).to eq(1)
      expect(counts.mismatch_call("live", "uncalled") + counts.matched_call("live", "uncalled")).to eq(0)
    end

    it "splits every call count by source" do
      solve!("live", human_call: "judge_right", human_called_at: Time.current)
      solve!("replay", source: "replay", human_call: "judge_right", human_called_at: Time.current)
      synthetic!("syn", human_call: "judge_right", human_called_at: Time.current)
      synthetic!("syn_ok", matched: true, judge_pick: "a", human_call: "both_defensible", human_called_at: Time.current)

      expect(JudgeSolve::SOURCES.map { |source| counts.mismatch_call(source, "judge_right") }).to eq([ 1, 1, 1 ])
      expect(JudgeSolve::SOURCES.map { |source| counts.matched_call(source, "both_defensible") }).to eq([ 0, 0, 1 ])
    end
  end
end
