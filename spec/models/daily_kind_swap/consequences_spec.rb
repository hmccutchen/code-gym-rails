require "rails_helper"

RSpec.describe DailyKindSwap::Consequences do
  def kind(key) = ExerciseSection.find(key)

  def consequences(kind_key, place: 0, pair: DailyKinds::DEFAULT, weights: {}, excluded: [], practice_policy: :inactive)
    described_class.for(pair: pair, place: place, kind: kind(kind_key),
                        preferences: KindPreferences.new(weights: weights, excluded: excluded), practice_policy: practice_policy)
  end

  def t(key, **values) = I18n.t("daily_kinds.picker.consequences.#{key}", **values)

  describe "sentences for the incoming kind" do
    it "names the two siblings a daily fourth keeps out of rotation" do
      expect(consequences("plan_review").sentences)
        .to include(t(:fourth_siblings, siblings: "Ambiguity Hunt and Pseudocode to Code", kind: "Plan Review"))
    end

    it "never promises that two regular preferences share a concept in one session" do
      expect(consequences("architecture").sentences.join).not_to include("same day", "same idea")
    end

    it "names a stored weight as more or less often, and stays quiet at the default" do
      expect(consequences("challenge", weights: { "challenge" => 2.0 }).sentences).to include(t(:weight_more, kind: "Coding Challenge"))
      expect(consequences("challenge", weights: { "challenge" => 0.5 }).sentences).to include(t(:weight_less, kind: "Coding Challenge"))
      expect(consequences("challenge", weights: { "challenge" => 1.0 }).sentences.join).not_to include("Exercise mix")
    end

    %i[active inactive].each do |policy|
      it "explains that Skip does not remove a regular choice under #{policy} practice without promising every set" do
        sentences = consequences("challenge", excluded: %w[challenge], practice_policy: policy).sentences

        expect(sentences).to include(t(:excluded_incoming, kind: "Coding Challenge"))
        expect(sentences.join).to include("Skip does not remove it from your regular sections.")
        expect(sentences.join).not_to include("every set")
      end
    end
  end

  describe "the warning about the outgoing kind" do
    %i[active inactive].each do |policy|
      it "describes future recommendation eligibility under #{policy} practice" do
        expect(consequences("challenge", practice_policy: policy).warning)
          .to eq([ I18n.t("protected_practice.daily_kinds.outgoing", outgoing: "Code Review") ])
      end
    end

    it "reports unavailable practice rules instead of predicting eligibility" do
      expect(consequences("challenge", practice_policy: :unavailable).warning)
        .to eq([ I18n.t("protected_practice.unavailable") ])
    end

    it "names the stored exclusion of an outgoing kind" do
      pair     = [ kind("challenge"), kind("design_comparison") ]
      expected = [ t(:outgoing_excluded, outgoing: "Coding Challenge") ]

      expect(consequences("code_review", pair: pair, excluded: %w[challenge]).warning).to eq(expected)
    end

    it "warns when a singleton kind has a stored exclusion" do
      expect(consequences("challenge", excluded: %w[code_review]).warning)
        .to eq([ t(:outgoing_excluded, outgoing: "Code Review") ])
    end

    it "puts a fourth replacing a fourth ahead of every size rule" do
      pair = [ kind("code_review"), kind("plan_review") ]

      expect(consequences("ambiguity_hunt", place: 1, pair: pair).warning)
        .to eq([ t(:outgoing_one_fourth, outgoing: "Plan Review", kind: "Ambiguity Hunt") ])
    end
  end
end
