require "rails_helper"

RSpec.describe ConceptMastery::Transition do
  let(:state) do
    { "tier" => "standard", "streak" => 2, "last_rating" => "developing", "cooldown_remaining" => 0,
      "mastered_at" => "2026-10-01T12:00:00.123456Z", "retention_interval_days" => 7,
      "next_retention_check_on" => "2026-11-05", "drilled_at" => "2026-11-04T12:00:00.123456Z", "drill_group" => nil }
  end
  let(:review) do
    { "type" => "review", "response_id" => 1, "work_on" => "2026-11-05", "reviewed_on" => "2026-11-06",
      "occurred_at" => "2026-11-06T12:00:00.123456Z",
      "sections" => { "pattern" => { "rating" => "developing", "self_rating" => "right_level" } }, "pending_sections" => [] }
  end

  def apply(changes = {}, rating: "developing", self_rating: "right_level")
    described_class.apply(state.merge(changes), review.deep_merge(
      "sections" => { "pattern" => { "rating" => rating, "self_rating" => self_rating } }))
  end

  it "steps stagnant standard and reduced states down and clears only the schedule" do
    expect(apply).to eq(state.merge("tier" => "reduced", "streak" => 0,
      "retention_interval_days" => nil, "next_retention_check_on" => nil))
    expect(apply({ "tier" => "reduced", "streak" => 1 })).to eq(state.merge("tier" => "paused", "streak" => 0,
      "cooldown_remaining" => 2, "retention_interval_days" => nil, "next_retention_check_on" => nil))
  end

  it "counts sessions while paused, exits at reduced and ignores reviews while paused" do
    paused = state.merge("tier" => "paused", "cooldown_remaining" => 2)
    once = described_class.apply(paused, "type" => "session", "response_id" => 2)
    expect(once).to eq(paused.merge("cooldown_remaining" => 1))
    expect(described_class.apply(once, "type" => "session", "response_id" => 3)).to eq(
      paused.merge("tier" => "reduced", "streak" => 0, "cooldown_remaining" => 0))
    expect(described_class.apply(once, review)).to eq(once)
  end

  it "grows only due intervals and schedules from the recorded review day" do
    expect(apply({}, rating: "strong")).to eq(state.merge("streak" => 0, "last_rating" => "strong",
      "retention_interval_days" => 14, "next_retention_check_on" => "2026-11-20", "drilled_at" => nil))
    expect(apply({ "next_retention_check_on" => "2026-11-07" }, rating: "strong")).to include(
      "retention_interval_days" => 7, "next_retention_check_on" => "2026-11-13")
    expect(apply({ "retention_interval_days" => 56 }, rating: "strong")).to include("retention_interval_days" => 60)
  end

  it "resets baseline and improving failures without starting retention" do
    expect(apply({ "last_rating" => nil }, self_rating: "too_hard")).to include(
      "streak" => 0, "last_rating" => "developing", "retention_interval_days" => nil)
    expect(apply({ "streak" => 1 }, rating: "solid", self_rating: "too_hard")).to include(
      "streak" => 0, "last_rating" => "solid", "retention_interval_days" => nil)
  end

  it "retains current comfortable eased-success policy" do
    expect(apply({ "tier" => "reduced" }, rating: "strong")).to include("tier" => "standard", "retention_interval_days" => 14)
  end

  it "uses the weakest grade and all favourable self-ratings without mutating inputs" do
    operation = review.deep_merge("sections" => { "code_review" => { "rating" => "strong", "self_rating" => nil } })
    original = state.deep_dup
    expect(described_class.apply(state, operation)).to include("tier" => "reduced", "last_rating" => "developing")
    expect(state).to eq(original)
  end
end
