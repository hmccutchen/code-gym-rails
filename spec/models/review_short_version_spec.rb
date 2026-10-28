require "rails_helper"

RSpec.describe ReviewShortVersion do
  let(:day) { Date.new(2026, 10, 20) }
  let(:earlier_day) { Date.new(2026, 10, 13) }
  let(:answer) { "Preload the customers with includes before the loop." }

  def response_for(tags:, reviews: {}, answers: nil)
    sections = tags.keys
    exercise = DailyExercise.new(date: day, language: "ruby_rails", generated_at: Time.current,
                                 problem_set: sections.index_with { |section| { "concept" => tags[section] } })
    DailyResponse.new(daily_exercise: exercise, date: day, submitted_at: Time.current,
                      answers: answers || sections.index_with { answer },
                      concept_tags: tags, ai_review: reviews)
  end

  def exposures(seen)
    ConceptExposureIndex.new(seen.to_h { |concept, dates| [ [ concept, "ruby_rails" ], Set.new(dates) ] })
  end

  def review(rating, missed: [ "Loads each customer in its own query." ], gaps: nil)
    { "rating" => rating, "missed" => missed, "essential_gaps" => gaps }.compact
  end

  describe "#offered?" do
    it "offers it on a concept's first exposure, whatever the grade" do
      response = response_for(tags: { "code_review" => "n_plus_one" }, reviews: { "code_review" => review("solid") })

      expect(described_class.new(response, exposures: exposures("n_plus_one" => [ day ])).offered?("code_review")).to be(true)
    end

    it "offers it on a later exposure only with a low grade" do
      seen = exposures("n_plus_one" => [ earlier_day, day ])
      solid = response_for(tags: { "code_review" => "n_plus_one" }, reviews: { "code_review" => review("solid") })
      developing = response_for(tags: { "code_review" => "n_plus_one" }, reviews: { "code_review" => review("developing") })

      expect(described_class.new(solid, exposures: seen).offered?("code_review")).to be(false)
      expect(described_class.new(developing, exposures: seen).offered?("code_review")).to be(true)
    end

    it "offers it to a skipped section on its first exposure only" do
      skipped = response_for(tags: { "code_review" => "n_plus_one" }, answers: {},
                             reviews: { "code_review" => { "missed" => [ "What a good answer covers." ] } })

      expect(described_class.new(skipped, exposures: exposures("n_plus_one" => [ day ])).offered?("code_review")).to be(true)
      expect(described_class.new(skipped, exposures: exposures("n_plus_one" => [ earlier_day, day ])).offered?("code_review")).to be(false)
    end

    it "never offers it for a blank or \"other\" tag" do
      blank = response_for(tags: { "code_review" => "" }, reviews: { "code_review" => review("beginner") })
      other = response_for(tags: { "code_review" => "other" }, reviews: { "code_review" => review("beginner") })

      expect(described_class.new(blank, exposures: exposures({})).offered?("code_review")).to be(false)
      expect(described_class.new(other, exposures: exposures({})).offered?("code_review")).to be(false)
    end

    it "offers it once, on the first qualifying section, when two share a concept" do
      response = response_for(tags: { "code_review" => "n_plus_one", "pattern" => "n_plus_one" },
                              reviews: { "code_review" => review("solid"), "pattern" => review("solid") })
      short_version = described_class.new(response, exposures: exposures("n_plus_one" => [ day ]))

      expect(short_version.offered?("code_review")).to be(true)
      expect(short_version.offered?("pattern")).to be(false)
    end

    it "passes over an earlier section sharing the concept whose review failed in a partial review" do
      response = response_for(tags: { "code_review" => "n_plus_one", "pattern" => "n_plus_one" },
                              reviews: { "pattern" => review("solid") })
      short_version = described_class.new(response, exposures: exposures("n_plus_one" => [ day ]))

      expect(short_version.offered?("code_review")).to be(false)
      expect(short_version.offered?("pattern")).to be(true)
    end

    it "passes over an earlier section that doesn't qualify" do
      response = response_for(tags: { "code_review" => "n_plus_one", "pattern" => "n_plus_one" },
                              reviews: { "code_review" => review("solid"), "pattern" => review("developing") })
      short_version = described_class.new(response, exposures: exposures("n_plus_one" => [ earlier_day, day ]))

      expect(short_version.offered?("code_review")).to be(false)
      expect(short_version.offered?("pattern")).to be(true)
    end
  end

  describe "#key" do
    it "is the concept and the bucket the section records under, or nil for a tag that doesn't count" do
      response = response_for(tags: { "code_review" => "n_plus_one", "pattern" => "other" })
      short_version = described_class.new(response, exposures: exposures({}))

      expect(short_version.key("code_review")).to eq(ConceptExposureIndex.key_for("code_review", "n_plus_one", "ruby_rails"))
      expect(short_version.key("pattern")).to be_nil
    end
  end

  describe "#pitfalls?" do
    let(:tags) { { "code_review" => "n_plus_one", "pattern" => "n_plus_one" } }
    let(:seen) { exposures("n_plus_one" => [ day ]) }

    it "shows pitfalls on the offering section when a later section sharing the concept has the gap" do
      response = response_for(tags: tags, reviews: { "code_review" => review("solid", gaps: []), "pattern" => review("developing", gaps: [ 0 ]) })

      expect(described_class.new(response, exposures: seen).pitfalls?("code_review")).to be(true)
    end

    it "shows none when no section sharing the concept has a gap" do
      response = response_for(tags: tags, reviews: { "code_review" => review("solid", gaps: []), "pattern" => review("strong", gaps: []) })

      expect(described_class.new(response, exposures: seen).pitfalls?("code_review")).to be(false)
    end

    it "ignores a gap on a section with another concept" do
      response = response_for(tags: { "code_review" => "n_plus_one", "pattern" => "memoization" },
                              reviews: { "code_review" => review("solid", gaps: []), "pattern" => review("developing", gaps: [ 0 ]) })

      expect(described_class.new(response, exposures: seen).pitfalls?("code_review")).to be(false)
    end
  end

  describe "#essential_gap?" do
    def gap?(section_review, answers: nil)
      response = response_for(tags: { "code_review" => "n_plus_one" }, reviews: { "code_review" => section_review }, answers: answers)
      described_class.new(response, exposures: exposures({})).essential_gap?("code_review")
    end

    it "reads each case from the section's own rating and the review as graded" do
      reworded = review("solid", missed: [ "Reworded." ]).merge(
        ReviewProseVerdict::ORIGINAL_KEY => { "missed" => [ "As graded." ], "essential_gaps" => [ 0 ] }
      )

      aggregate_failures do
        expect(gap?(review("solid", gaps: [ 0 ]))).to be(true)
        expect(gap?(reworded)).to be(true)
        expect(gap?(review("developing", gaps: []))).to be(true)
        expect(gap?(review("developing"))).to be(true)
        expect(gap?(review("solid", gaps: []))).to be(false)
        expect(gap?(review("solid"))).to be(false)
        expect(gap?(review("beginner", missed: []))).to be(true)
        expect(gap?(review("developing", gaps: [ 0 ]), answers: {})).to be(false)
      end
    end
  end
end
