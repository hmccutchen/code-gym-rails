require "rails_helper"

RSpec.describe ConceptMastery::Reconciliation do
  let(:baseline) do
    { "tier" => "reduced", "streak" => 1, "last_rating" => "developing", "cooldown_remaining" => 0,
      "mastered_at" => nil, "retention_interval_days" => nil, "next_retention_check_on" => nil,
      "drilled_at" => "2026-11-04T12:00:00.123456Z", "drill_group" => nil }
  end

  def review(id = 1, rating: "strong", pending: %w[code_review])
    { "type" => "review", "response_id" => id, "work_on" => "2026-11-05", "reviewed_on" => "2026-11-05",
      "occurred_at" => "2026-11-05T12:00:00.123456Z", "pending_sections" => pending,
      "sections" => { "pattern" => { "rating" => rating, "self_rating" => "right_level" } } }
  end

  def append(result, operation)
    described_class.apply(current: result.state, journal: result.journal, operation: operation)
  end

  def opened
    described_class.apply(current: baseline, journal: {}, operation: review)
  end

  it "replaces the first position and retains originally no-op session attempts" do
    result = opened
    expect(result.state).to include("tier" => "standard", "drilled_at" => nil)
    [ 2, 3 ].each { |id| result = append(result, "type" => "session", "response_id" => id) }
    result = append(result, review(rating: "developing", pending: []))
    expect(result.state).to eq(baseline.merge("tier" => "reduced", "streak" => 0, "cooldown_remaining" => 0))
    expect(result.journal).to eq({})
  end

  it "preserves later review position and clocks without reading a wall clock" do
    result = append(opened, review(2, pending: []).merge("occurred_at" => "2026-11-06T12:00:00.123456Z",
      "reviewed_on" => "2026-11-06"))
    expect(Time).not_to receive(:current)
    expect(Date).not_to receive(:current)
    result = append(result, review(pending: []).merge("reviewed_on" => "2026-11-09"))
    expect(result.state).to include("mastered_at" => "2026-11-05T12:00:00.123456Z",
      "next_retention_check_on" => "2026-11-13", "last_rating" => "strong")
  end

  it "keeps two open days and compacts only the irrevocable prefix" do
    result = append(opened, review(2))
    closed_newest = append(result, review(2, pending: []))
    expect(closed_newest.journal["operations"].size).to eq(2)
    closed_oldest = append(result, review(pending: []))
    expect(closed_oldest.journal["operations"].map { |op| op["response_id"] }).to eq([ 2 ])
    expect(append(closed_newest, review(pending: [])).journal).to eq({})
  end

  it "retains skipped-check attempts which become due only under the corrected past" do
    initial = baseline.merge("tier" => "standard", "streak" => 0, "retention_interval_days" => 7,
      "next_retention_check_on" => "2026-11-05")
    result = described_class.apply(current: initial, journal: {}, operation: review(rating: "developing"))
    result = append(result, "type" => "skip", "response_id" => 2, "work_on" => "2026-11-19", "reviewed_on" => "2026-11-20")
    result = append(result, review(pending: []))
    expect(result.state["next_retention_check_on"]).to eq("2026-12-04")
  end

  it "preserves explicit stop and later restart rather than obsolete baseline group identity" do
    result = opened
    expect(described_class.restorable_drill(journal: result.journal)).to eq(
      "drilled_at" => baseline["drilled_at"], "drill_group" => nil)
    result = append(result, "type" => "drill", "action" => "clear")
    expect(described_class.restorable_drill(journal: result.journal)).to be_nil
    set = { "type" => "drill", "action" => "set", "drilled_at" => "2026-11-06T12:00:00.123456Z",
      "drill_group" => "rails_data", "end_pause" => true }
    result = append(result, set)
    result = append(result, review(rating: "developing", pending: []))
    expect(result.state).to include(set.slice("drilled_at", "drill_group").merge("tier" => "reduced"))
    expect(described_class.restorable_drill(journal: result.journal)).to be_nil
  end

  it "does not truncate a long unresolved suffix" do
    result = opened
    90.times { |index| result = append(result, "type" => "session", "response_id" => index + 2) }
    expect(result.journal["operations"].size).to eq(91)
    expect(append(result, review(rating: "developing", pending: [])).state["tier"]).to eq("reduced")
  end

  it "reconsiders a later review originally ignored while paused" do
    result = described_class.apply(current: baseline, journal: {}, operation: review(rating: "developing"))
    result = append(result, review(2, rating: "solid", pending: []).merge(
      "occurred_at" => "2026-11-06T12:00:00.123456Z", "reviewed_on" => "2026-11-06"))
    expect(result.state["last_rating"]).to eq("developing")
    result = append(result, review(pending: []))
    expect(result.state).to include("last_rating" => "solid", "tier" => "standard", "next_retention_check_on" => "2026-11-13")
  end

  it "reconsiders a later skip that was originally applicable but becomes unscheduled" do
    result = append(opened, "type" => "skip", "response_id" => 2, "work_on" => "2026-11-12", "reviewed_on" => "2026-11-13")
    expect(result.state["next_retention_check_on"]).to eq("2026-11-20")
    result = append(result, review(rating: "developing", pending: []))
    expect(result.state["next_retention_check_on"]).to be_nil
  end

  [ nil, [], "text", false, 0, { "version" => 2 }, { "version" => 1 } ].each do |bad|
    it "rejects #{bad.inspect} rather than resetting it" do
      expect { described_class.apply(current: baseline, journal: bad, operation: review) }.to raise_error(ArgumentError)
      expect { described_class.restorable_drill(journal: bad) }.to raise_error(ArgumentError)
    end
  end

  it "rejects unrecognized fields, bad grades and malformed clocks" do
    [ review.merge("secret" => "no"), review(rating: "unknown"), review.merge("reviewed_on" => "tomorrow") ].each do |operation|
      expect { described_class.apply(current: baseline, journal: {}, operation: operation) }.to raise_error(ArgumentError)
    end
    malformed = opened.journal.deep_merge("baseline" => { "streak" => "one" })
    expect { described_class.restorable_drill(journal: malformed) }.to raise_error(ArgumentError)
  end

  it "refuses an invalid materialized baseline before opening a suffix" do
    expect do
      described_class.apply(current: baseline.merge("last_rating" => "unknown"), journal: {}, operation: review)
    end.to raise_error(ArgumentError)
  end

  [
    { "type" => "clear", "action" => "clear" },
    { "type" => "set", "action" => "clear", "drilled_at" => "2026-11-06T17:00:00.000000Z",
      "drill_group" => nil, "end_pause" => false },
    { "type" => "drill", "action" => "review" },
    { "type" => "drill", "action" => nil }
  ].each do |operation|
    it "rejects the discriminator #{operation.slice('type', 'action').inspect} at every suffix boundary", :aggregate_failures do
      journal = opened.journal
      journal["operations"] << operation
      expect { described_class.decode(journal) }.to raise_error(ArgumentError)
      expect { described_class.restorable_drill(journal: journal) }.to raise_error(ArgumentError)
      expect { append(opened, operation) }.to raise_error(ArgumentError)
    end
  end

  it "accepts supported drill actions at the decode and restorable-intent boundaries" do
    result = append(opened, "type" => "drill", "action" => "set", "drilled_at" => "2026-11-06T17:00:00.000000Z",
      "drill_group" => "module_design", "end_pause" => false)
    expect(described_class.decode(result.journal)).to eq(result.journal)
    expect(described_class.restorable_drill(journal: result.journal)).to eq(
      "drilled_at" => "2026-11-06T17:00:00.000000Z", "drill_group" => "module_design")
    result = append(result, "type" => "drill", "action" => "clear")
    expect(described_class.decode(result.journal)).to eq(result.journal)
    expect(described_class.restorable_drill(journal: result.journal)).to be_nil
  end
end
