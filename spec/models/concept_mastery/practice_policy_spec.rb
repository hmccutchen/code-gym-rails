require "rails_helper"

RSpec.describe ConceptMastery::PracticePolicy do
  let(:clock) { "2026-11-06T12:00:00.123456Z" }
  let(:state) do
    { "tier" => "reduced", "streak" => 1, "last_rating" => "developing", "cooldown_remaining" => 0,
      "mastered_at" => nil, "retention_interval_days" => nil, "next_retention_check_on" => nil,
      "drilled_at" => clock, "drill_group" => nil, "practice_requests" => {} }
  end

  def operation(eased: true, rating: "solid", self_rating: "right_level", pending: [])
    { "type" => "review", "policy" => 2, "response_id" => 17, "work_on" => "2026-11-06",
      "reviewed_on" => "2026-11-06", "occurred_at" => clock, "pending_sections" => pending,
      "sections" => { "pattern" => { "rating" => rating, "self_rating" => self_rating, "eased" => eased } } }
  end

  def apply(input = state, **keywords)
    described_class.apply(state: input, operation: operation(**keywords))
  end

  it "returns eased comfort to standard practice without granting retention or releasing the admitted drill" do
    result = apply
    expect(result).to include("tier" => "standard", "streak" => 0, "drilled_at" => clock,
      "mastered_at" => nil, "retention_interval_days" => nil, "next_retention_check_on" => nil)
    expect(result.fetch("practice_requests")).to eq("pattern" => {
      "mode" => "normal_retry", "source_response_id" => 17, "requested_at" => clock
    })
    normal = apply(result, eased: false)
    expect(normal).to include("drilled_at" => nil, "mastered_at" => clock,
      "next_retention_check_on" => "2026-11-13", "practice_requests" => {})
  end

  it "preserves previously earned retention byte for byte on all-eased comfort" do
    earned = state.merge("mastered_at" => "2026-10-01T10:00:00.654321Z",
      "retention_interval_days" => 14, "next_retention_check_on" => "2026-11-01")
    expect(apply(earned).slice("mastered_at", "retention_interval_days", "next_retention_check_on"))
      .to eq(earned.slice("mastered_at", "retention_interval_days", "next_retention_check_on"))
  end

  it "records a retry while preserving a pause and its countdown" do
    expect(apply(state.merge("tier" => "paused", "cooldown_remaining" => 2)))
      .to include("tier" => "paused", "cooldown_remaining" => 2,
        "practice_requests" => include("pattern" => include("mode" => "normal_retry")))
  end

  it "distinguishes support from simplified reasoning and preserves missing-rating intent" do
    hard = apply(rating: "developing", self_rating: "too_hard")
    expect(hard.dig("practice_requests", "pattern", "mode")).to eq("simplified")
    expect(apply(hard, rating: "developing").dig("practice_requests", "pattern", "mode")).to eq("simplified")
    supported = apply(hard, self_rating: "too_hard")
    expect(supported.dig("practice_requests", "pattern", "mode")).to eq("support")
    expect(apply(supported, eased: false, self_rating: nil)["practice_requests"]).to eq(supported["practice_requests"])
    retrying = apply
    expect(apply(retrying, eased: false, rating: "developing").dig("practice_requests", "pattern", "mode")).to eq("support")
  end

  it "requires comfort across siblings while retaining each kind's normal-practice request" do
    mixed = operation
    mixed["sections"]["code_review"] = { "rating" => "strong", "self_rating" => "right_level", "eased" => false }
    result = described_class.apply(state: state, operation: mixed)
    expect(result).to include("mastered_at" => clock, "drilled_at" => nil)
    expect(result["practice_requests"].keys).to eq([ "pattern" ])
    mixed["sections"]["pattern"]["rating"] = "developing"
    expect(described_class.apply(state: state, operation: mixed)["retention_interval_days"]).to be_nil
  end

  it "folds a v1 correction before v2 and subsequent Stop/Start at their original clocks" do
    legacy = operation(pending: %w[code_review]).except("policy")
    legacy["sections"].each_value { |entry| entry.delete("eased") }
    fold = ConceptMastery::Reconciliation
    result = fold.apply(current: state.except("practice_requests"), journal: {}, operation: legacy)
    v2 = operation.merge("response_id" => 18, "occurred_at" => "2026-11-07T01:02:03.654321Z", "reviewed_on" => "2026-11-07")
    result = fold.apply(current: result.state, journal: result.journal, operation: v2)
    expect(result.journal["version"]).to eq(2)
    expect(result.journal["operations"].first["policy"]).to eq(1)
    result = fold.apply(current: result.state, journal: result.journal, operation: { "type" => "drill", "action" => "clear" })
    start = { "type" => "drill", "action" => "set", "drilled_at" => "2026-11-08T01:02:03.456789Z",
      "drill_group" => nil, "end_pause" => true }
    result = fold.apply(current: result.state, journal: result.journal, operation: start)
    legacy["sections"]["code_review"] = { "rating" => "beginner", "self_rating" => "too_hard" }
    legacy["pending_sections"] = []
    result = fold.apply(current: result.state, journal: result.journal, operation: legacy)
    expect(result.journal).to eq({})
    expect(result.state).to include("drilled_at" => start["drilled_at"], "mastered_at" => nil,
      "retention_interval_days" => nil, "practice_requests" => include(
        "pattern" => include("mode" => "normal_retry", "requested_at" => v2["occurred_at"])))
  end

  it "preserves extended baseline state when a v1 prefix compacts before an open v2 contribution" do
    fold = ConceptMastery::Reconciliation
    initial = apply
    legacy = operation(pending: %w[code_review]).except("policy")
    legacy["sections"].each_value { |entry| entry.delete("eased") }
    result = fold.apply(current: initial, journal: {}, operation: legacy)
    result = fold.apply(current: result.state, journal: result.journal, operation: operation(pending: %w[code_review]).merge("response_id" => 18))
    result = fold.apply(current: result.state, journal: result.journal, operation: legacy.merge("pending_sections" => []))
    expect(result.journal.dig("baseline", "practice_requests")).to eq(initial["practice_requests"])
    closing = operation(pending: []).merge("response_id" => 18)
    result = fold.apply(current: result.state, journal: result.journal, operation: closing)
    expect(result.journal).to eq({})
    expect(result.state).to eq("tier" => "standard", "streak" => 0, "last_rating" => "solid", "cooldown_remaining" => 0,
      "mastered_at" => clock, "retention_interval_days" => 7, "next_retention_check_on" => "2026-11-13",
      "drilled_at" => nil, "drill_group" => nil, "practice_requests" => {
        "pattern" => { "mode" => "normal_retry", "source_response_id" => 18, "requested_at" => clock }
      })
  end

  it "matches a serialized v1 oracle through later review, session, skip, Stop/Start and final correction" do
    fixture = JSON.parse(File.read(Rails.root.join("spec/fixtures/practice/v1-replay.json")))
    journal = fixture.fetch("journal")
    folded = journal.fetch("operations").reduce(journal.fetch("baseline")) { |state, event| ConceptMastery::Transition.apply(state, event) }
    expect(folded).to eq(fixture.fetch("materialized"))
    correcting = journal.fetch("operations").first.deep_dup
    correcting["sections"]["code_review"] = { "rating" => "beginner", "self_rating" => "too_hard" }
    correcting["pending_sections"] = []
    result = ConceptMastery::Reconciliation.apply(current: fixture.fetch("materialized"), journal: journal, operation: correcting)
    expect(result.state).to eq(fixture.fetch("corrected"))
    expect(result.journal).to eq({})
    expect(result.state.keys).to match_array(ConceptMastery::Transition::FIELDS)
  end

  it "reads a frozen v1 journal unchanged and keeps its nine-field baseline when initiation is off" do
    raw = JSON.parse(File.read(Rails.root.join("spec/fixtures/practice/v1-journal.json"))).freeze
    expect(ConceptMastery::Reconciliation.decode(raw)).to eq(raw)
    current = ConceptMastery::Transition.apply(raw["baseline"], raw["operations"].first)
    folded = ConceptMastery::Reconciliation.apply(current: current, journal: raw, operation: { "type" => "drill", "action" => "clear" })
    expect(folded.journal).to include("version" => 1, "baseline" => raw["baseline"])
    expect(folded.journal["operations"].first).to eq(raw["operations"].first)
    expect(folded.state).not_to have_key("practice_requests")
  end

  it "passes requests through countdown, skip and every manual transition" do
    requested = apply
    operations = [
      { "type" => "session", "response_id" => 18 },
      { "type" => "skip", "response_id" => 18, "work_on" => "2026-11-07", "reviewed_on" => "2026-11-07" },
      { "type" => "drill", "action" => "clear" },
      { "type" => "drill", "action" => "set", "drilled_at" => clock, "drill_group" => nil, "end_pause" => true },
      { "type" => "drill", "action" => "set", "drilled_at" => clock, "drill_group" => "performance", "end_pause" => false }
    ]
    operations.each do |event|
      result = ConceptMastery::Reconciliation.apply(current: requested, journal: {}, operation: event)
      expect(result.state["practice_requests"]).to eq(requested["practice_requests"])
    end
  end

  [ 1, 2 ].each do |policy|
    it "converges across every sibling arrival order under fixed policy #{policy} and later v2 manual work" do
      fold = ConceptMastery::Reconciliation
      sections = {
        "pattern" => { "rating" => "solid", "self_rating" => "right_level", "eased" => true },
        "code_review" => { "rating" => "developing", "self_rating" => "too_hard", "eased" => false },
        "challenge" => { "rating" => "strong", "self_rating" => "right_level", "eased" => false }
      }
      sections.transform_values! { |entry| entry.except("eased") } if policy == 1
      first = operation.merge("sections" => sections).then { |entry| policy == 1 ? entry.except("policy") : entry }
      later = operation.merge("response_id" => 18, "occurred_at" => "2026-11-07T01:02:03.456789Z")
      manual = { "type" => "drill", "action" => "set", "drilled_at" => "2026-11-08T01:02:03.654321Z",
        "drill_group" => nil, "end_pause" => true }
      expected = [ first, later, manual ].reduce(fold::Result.new(state: state, journal: {})) do |previous, event|
        fold.apply(current: previous.state, journal: previous.journal, operation: event)
      end
      sections.keys.permutation.each do |order|
        partial = first.merge("sections" => sections.slice(order.first), "pending_sections" => order.drop(1))
        actual = [ partial, later, manual ].reduce(fold::Result.new(state: state, journal: {})) do |previous, event|
          fold.apply(current: previous.state, journal: previous.journal, operation: event)
        end
        order.drop(1).each_with_index do |_key, index|
          event = first.merge("sections" => sections.slice(*order.first(index + 2)), "pending_sections" => order.drop(index + 2))
          actual = fold.apply(current: actual.state, journal: actual.journal, operation: event)
        end
        expect(actual).to eq(expected)
      end
    end
  end
end
