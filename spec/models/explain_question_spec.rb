require "rails_helper"

RSpec.describe ExplainQuestion do
  def option(section, concept, sections = [ section ])
    described_class::Option.new(section: section, concept: concept, sections: sections)
  end

  describe ".options" do
    it "lists the day's usable concepts in the day's section order" do
      tags = [ [ "code_review", "n_plus_one" ], [ "design_comparison", "service_objects" ], [ "pattern", "callbacks" ] ]

      expect(described_class.options(tags: tags).map(&:section)).to eq(%w[code_review design_comparison pattern])
    end

    it "leaves out a section with no usable tag, which the caller passes as nil" do
      tags = [ [ "code_review", nil ], [ "pattern", "callbacks" ] ]

      expect(described_class.options(tags: tags)).to eq([ option("pattern", "callbacks") ])
    end

    it "gives two sections sharing a concept one option, held by the first of them" do
      tags = [ [ "code_review", "n_plus_one" ], [ "pattern", "callbacks" ], [ "challenge", "n_plus_one" ] ]

      expect(described_class.options(tags: tags))
        .to eq([ option("code_review", "n_plus_one", %w[code_review challenge]), option("pattern", "callbacks") ])
    end

    it "gives none when no tag is usable" do
      expect(described_class.options(tags: [ [ "code_review", nil ] ])).to eq([])
    end
  end

  describe ".default" do
    let(:options) do
      [ option("code_review", "n_plus_one"), option("design_comparison", "service_objects"), option("pattern", "callbacks") ]
    end

    def default(duck_turns: {}, cleared: {}, too_hard: [], recent: [], from: options)
      described_class.default(options: from, duck_turns: duck_turns, cleared: cleared, too_hard: too_hard, recent: recent)&.section
    end

    it "takes the first option when there is no duck or too-hard signal" do
      expect(default).to eq("code_review")
    end

    it "puts a section where the duck was used before one only rated too hard" do
      expect(default(duck_turns: { "pattern" => 1 }, too_hard: %w[code_review])).to eq("pattern")
    end

    it "counts a cleared section as duck use" do
      expect(default(cleared: { "pattern" => 1 }, too_hard: %w[design_comparison])).to eq("pattern")
    end

    it "puts more stored user turns first" do
      expect(default(duck_turns: { "code_review" => 1, "pattern" => 3 })).to eq("pattern")
    end

    it "falls back to the day's order between equal signals" do
      expect(default(too_hard: %w[pattern design_comparison])).to eq("design_comparison")
    end

    it "reads a signal on either section of a shared concept" do
      shared = [ option("code_review", "n_plus_one", %w[code_review challenge]), option("pattern", "callbacks") ]

      expect(default(duck_turns: { "challenge" => 2 }, too_hard: %w[pattern], from: shared)).to eq("code_review")
    end

    it "skips a concept explained in the 7 days before when another option exists" do
      expect(default(recent: %w[n_plus_one])).to eq("design_comparison")
      expect(default(duck_turns: { "code_review" => 4 }, too_hard: %w[pattern], recent: %w[n_plus_one])).to eq("pattern")
    end

    it "keeps a recent concept when every option was explained recently" do
      expect(default(duck_turns: { "pattern" => 1 }, recent: %w[n_plus_one service_objects callbacks])).to eq("pattern")
    end

    it "picks nothing when there are no options" do
      expect(default(from: [])).to be_nil
    end
  end

  describe ".phrasing" do
    it "gives the three keys for none, one, and two or more earlier explanations" do
      expect([ 0, 1, 2, 7 ].map { |count| described_class.phrasing(count) })
        .to eq(%w[explain.first explain.second explain.third explain.third])
    end

    it "renders the three fixed phrasings with the concept's display name" do
      texts = described_class::PHRASINGS.map { |key| described_class.text(key, "n_plus_one") }

      expect(texts).to eq([ "In your own words, what does N plus one do?",
                            "When does N plus one go wrong, or when wouldn't you use it?",
                            "How would you explain N plus one to a teammate who's new to it?" ])
    end

    it "pins the third phrasing's wording" do
      expect(I18n.t("learner_questions.explain.third", concept: "%{concept}"))
        .to eq("How would you explain %{concept} to a teammate who's new to it?")
    end
  end
end
