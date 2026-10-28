require "rails_helper"

RSpec.describe DailyKindSwap::Consequences do
  def kind(key) = ExerciseSection.find(key)

  def consequences(kind_key, place: 0, pair: DailyKinds::DEFAULT, weights: {}, excluded: [], setting: nil, planned_size: 3,
                   brake: false, held: DailyKinds::COUNT, languages: %w[ruby_rails])
    described_class.for(pair: pair, place: place, kind: kind(kind_key),
                        preferences: KindPreferences.new(weights: weights, excluded: excluded),
                        day: described_class::Day.new(setting: setting, planned_size: planned_size, brake: brake, held: held),
                        languages: languages, pair_shares: described_class.shares_a_concept?(pair, languages))
  end

  def t(key, **values) = I18n.t("daily_kinds.picker.consequences.#{key}", **values)

  describe "sentences for the incoming kind" do
    it "names the two siblings a daily fourth keeps out of rotation" do
      expect(consequences("plan_review").sentences)
        .to include(t(:fourth_siblings, siblings: "Ambiguity Hunt and Pseudocode to Code", kind: "Plan Review"))
    end

    it "says the pair stops sharing a concept only when the current pair can and the new one cannot" do
      expect(consequences("architecture").sentences).to include(t(:shared_concept))
      expect(consequences("security_review").sentences).to include(t(:shared_concept))

      unshared = [ kind("code_review"), kind("architecture") ]
      expect(consequences("plan_review", place: 1, pair: unshared).sentences).not_to include(t(:shared_concept))
    end

    it "reads sharing from the kinds' own hostable concepts, not from fourth membership" do
      expect(consequences("pattern").sentences).not_to include(t(:shared_concept))
    end

    it "names a stored weight as more or less often, and stays quiet at the default" do
      expect(consequences("challenge", weights: { "challenge" => 2.0 }).sentences).to include(t(:weight_more, kind: "Coding Challenge"))
      expect(consequences("challenge", weights: { "challenge" => 0.5 }).sentences).to include(t(:weight_less, kind: "Coding Challenge"))
      expect(consequences("challenge", weights: { "challenge" => 1.0 }).sentences.join).not_to include("Exercise mix")
    end

    it "says an excluded incoming kind is in every set while it is daily" do
      expect(consequences("challenge", excluded: %w[challenge]).sentences).to include(t(:excluded_incoming, kind: "Coding Challenge"))
    end
  end

  describe "the warning about the outgoing kind" do
    it "warns of nothing at three or more sections" do
      expect(consequences("challenge", planned_size: 3).warning).to be_empty
      expect(consequences("challenge", setting: 4, planned_size: 2).warning).to be_empty
    end

    it "says a fixed setting of two keeps the outgoing kind out for good" do
      expect(consequences("challenge", setting: 2, planned_size: 3).warning).to eq([ t(:outgoing_fixed, count: 2, outgoing: "Code Review") ])
    end

    it "says the same of any fixed setting whose every place holds a daily kind, since nothing is left to rotate" do
      expect(consequences("challenge", setting: 1, planned_size: 1, held: 1).warning)
        .to eq([ t(:outgoing_fixed, count: 1, outgoing: "Code Review") ])
      expect(consequences("challenge", setting: 3, planned_size: 3, held: 3).warning)
        .to eq([ t(:outgoing_fixed, count: 3, outgoing: "Code Review") ])
    end

    it "says a place the setting hides changes nothing until the setting is raised, not that the outgoing kind disappears" do
      expect(consequences("challenge", place: 1, setting: 1, planned_size: 2, held: 1).warning)
        .to eq([ t(:hidden_place, count: 1, kind: "Coding Challenge") ])
    end

    it "warns of nothing under a larger setting with a place left to rotate" do
      expect(consequences("challenge", setting: 3, planned_size: 3, held: 2).warning).to be_empty
    end

    it "gives an Automatic two-section day the coverage estimate and the gate sentence" do
      warning = consequences("challenge", planned_size: 2).warning

      expect(warning).to eq([ t(:outgoing_weeks, outgoing: "Code Review", weeks: 8), t(:outgoing_gate) ])
    end

    it "gives no weeks figure while the brake holds, since coverage adds nothing then" do
      warning = consequences("challenge", planned_size: 2, brake: true).warning

      expect(warning).to eq([ t(:outgoing_braked, outgoing: "Code Review"), t(:outgoing_gate) ])
      expect(warning.join).not_to include("weeks")
    end

    it "derives the estimate from the coverage constants and the kinds the user has not excluded" do
      stub_const("CoverageException::CAP_WEEKDAYS", 9)

      expect(consequences("challenge", planned_size: 2).warning.first).to eq(t(:outgoing_weeks, outgoing: "Code Review", weeks: 16))
      expect(consequences("challenge", planned_size: 2, excluded: %w[security_review parsons_problem]).warning.first)
        .to eq(t(:outgoing_weeks, outgoing: "Code Review", weeks: 12))
    end

    it "never estimates fewer weekdays than the coverage gap allows" do
      stub_const("CoverageException::GAP_WEEKDAYS", 60)

      expect(consequences("challenge", planned_size: 2).warning.first).to eq(t(:outgoing_weeks, outgoing: "Code Review", weeks: 12))
    end

    it "says an excluded outgoing kind never returns, whatever the day size" do
      pair     = [ kind("challenge"), kind("design_comparison") ]
      expected = [ t(:outgoing_excluded, outgoing: "Coding Challenge") ]

      expect(consequences("code_review", pair: pair, excluded: %w[challenge], planned_size: 4).warning).to eq(expected)
      expect(consequences("code_review", pair: pair, excluded: %w[challenge], planned_size: 2).warning).to eq(expected)
    end

    it "lets an excluded single-kind group still rotate at three sections, so it warns only at two" do
      expect(consequences("challenge", excluded: %w[code_review], planned_size: 3).warning).to be_empty
      expect(consequences("challenge", excluded: %w[code_review], planned_size: 2).warning)
        .to eq([ t(:outgoing_excluded, outgoing: "Code Review") ])
    end

    it "puts a fourth replacing a fourth ahead of every size rule" do
      pair = [ kind("code_review"), kind("plan_review") ]

      expect(consequences("ambiguity_hunt", place: 1, pair: pair, setting: 2).warning)
        .to eq([ t(:outgoing_one_fourth, outgoing: "Plan Review", kind: "Ambiguity Hunt") ])
    end

    it "says nothing about size when the row records none" do
      expect(consequences("challenge", planned_size: nil).warning).to be_empty
    end
  end
end
