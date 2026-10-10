require "rails_helper"

RSpec.describe ReviewedSectionResults do
  let(:date) { Date.new(2026, 10, 14) }

  # Unsaved records: the extractor reads only the objects it is handed.
  def response(sections, submitted: true)
    exercise = DailyExercise.new(
      date: date,
      problem_set: sections.transform_values do |section|
        { "question" => "q", "snippet" => "s", "pitched_at" => section[:rung], "eased" => section[:eased] }.compact
      end
    )
    DailyResponse.new(
      daily_exercise: exercise, date: date, submitted_at: (Time.current if submitted),
      answers: sections.transform_values { |section| section.fetch(:answered, true) ? "a" * 20 : "" },
      section_ratings: sections.transform_values { |section| section.fetch(:self, "right_level") }.compact,
      ai_review: sections.reject { |_, section| section[:unreviewed] }.transform_values do |section|
        { "rating" => section.fetch(:ai, "solid"), "rubric" => section.fetch(:rubric, AiService::RUBRIC_VERSION) }.compact
      end
    )
  end

  it "returns one result per answered, reviewed, stamped section with its date, kind, level and ratings" do
    results = described_class.for(response({
      "code_review" => { rung: "senior", ai: "strong", self: "too_hard" },
      "pattern" => { rung: "junior" }
    }))

    expect(results).to eq([
      ReviewedSectionResults::Result.new(date: date, kind: "code_review", level: "senior",
                                         ai_rating: "strong", self_rating: "too_hard"),
      ReviewedSectionResults::Result.new(date: date, kind: "pattern", level: "junior",
                                         ai_rating: "solid", self_rating: "right_level")
    ])
  end

  it "orders a day's results by the section registry" do
    results = described_class.for(response({
      "plan_review" => { rung: "junior" }, "challenge" => { rung: "junior" }, "code_review" => { rung: "junior" }
    }))

    expect(results.map(&:kind)).to eq(ExerciseSection.keys & %w[plan_review challenge code_review])
  end

  it "leaves out skipped, unreviewed, eased and unstamped sections" do
    results = described_class.for(response({
      "code_review" => { rung: "junior", answered: false },
      "pattern" => { rung: "junior", unreviewed: true },
      "challenge" => { rung: "junior", eased: true },
      "plan_review" => {}
    }))

    expect(results).to eq([])
  end

  [ "excellent", "SOLID", { "level" => "solid" }, 3, nil ].each do |rating|
    it "leaves out an AI rating outside the closed list: #{rating.inspect}" do
      expect(described_class.for(response({ "code_review" => { rung: "junior", ai: rating } }))).to eq([])
    end
  end

  # A value outside KindDifficulty::LEVELS can neither earn nor cost anything.
  [ "expert", "SENIOR", "", [ "junior" ] ].each do |rung|
    it "leaves out a rung outside the closed list: #{rung.inspect}" do
      expect(described_class.for(response({ "code_review" => { rung: rung } }))).to eq([])
    end
  end

  it "keeps an invalid or missing self-rating as it was stored" do
    results = described_class.for(response({
      "code_review" => { rung: "junior", self: nil }, "pattern" => { rung: "junior", self: "meh" }
    }))

    expect(results.map(&:self_rating)).to eq([ nil, "meh" ])
  end

  it "reads nothing from a draft" do
    expect(described_class.for(response({ "code_review" => { rung: "junior" } }, submitted: false))).to eq([])
  end

  describe "include_eased:" do
    let(:with_eased) do
      response({ "code_review" => { rung: "junior" }, "challenge" => { rung: "junior", eased: true, self: "too_hard" } })
    end

    it "marks every result it returns by default as not eased" do
      expect(described_class.for(with_eased).map { |result| [ result.kind, result.eased ] }).to eq([ [ "code_review", false ] ])
    end

    it "returns eased sections marked as eased when asked" do
      results = described_class.for(with_eased, include_eased: true)

      expect(results.map { |result| [ result.kind, result.eased ] }).to eq([ [ "code_review", false ], [ "challenge", true ] ])
      expect(results.last.self_rating).to eq("too_hard")
    end
  end

  # An old or hand-edited row must not stop the gate, which runs on every plan.
  describe "malformed rows" do
    def malformed(**columns)
      response({ "code_review" => { rung: "junior" }, "pattern" => { rung: "junior" } }).tap do |row|
        columns.each { |column, value| row[column] = value }
      end
    end

    it "skips a section whose review is not a hash and keeps the rest" do
      row = malformed
      row.ai_review = row.ai_review.merge("pattern" => "solid")

      expect(described_class.for(row, require_rubric: true).map(&:kind)).to eq(%w[code_review])
    end

    it "skips a section whose problem is not a hash" do
      row = malformed
      row.daily_exercise.problem_set = row.daily_exercise.problem_set.merge("pattern" => "a bare string")

      expect(described_class.for(row).map(&:kind)).to eq(%w[code_review])
    end

    [ [ :ai_review, [ "solid" ] ], [ :answers, [ "a" * 40 ] ] ].each do |column, value|
      it "returns nothing when #{column} is not a hash" do
        expect(described_class.for(malformed(column => value))).to eq([])
      end
    end

    it "reads no self-rating when the ratings are not a hash" do
      expect(described_class.for(malformed(section_ratings: [ "right_level" ])).map(&:self_rating)).to eq([ nil, nil ])
    end
  end

  describe "Result predicates" do
    def result(ai: "solid", self_rating: "right_level")
      ReviewedSectionResults::Result.new(date: date, kind: "code_review", level: "junior", ai_rating: ai, self_rating: self_rating)
    end

    it "places the AI rating on the mastery rank" do
      expect(%w[beginner developing solid strong].map { |rating| result(ai: rating).at_or_above?("solid") })
        .to eq([ false, false, true, true ])
      expect(result(ai: "excellent").at_or_above?("beginner")).to be(false)
    end

    it "is favourable only with the bar met and a favourable self-rating together" do
      expect(result.favourable?(bar: "solid")).to be(true)
      expect(result(ai: "developing").favourable?(bar: "solid")).to be(false)
      expect(result(ai: "developing").favourable?(bar: "developing")).to be(true)
      expect(result(self_rating: "too_hard").favourable?(bar: "solid")).to be(false)
      expect(result(self_rating: nil).favourable?(bar: "solid")).to be(false)
    end

    it "is too hard only on the engineer's own too-hard rating" do
      expect(%w[too_easy right_level too_hard meh].map { |rating| result(self_rating: rating).too_hard? })
        .to eq([ false, false, true, false ])
    end

    it "takes the lowest favourable AI rating as the favourable bar" do
      expect(ReviewedSectionResults::FAVOURABLE_BAR).to eq("solid")
    end
  end

  describe "require_rubric:" do
    let(:stamped) do
      response({
        "code_review" => { rung: "junior" },
        "pattern" => { rung: "junior", rubric: nil },
        "challenge" => { rung: "junior", rubric: AiService::RUBRIC_VERSION + 1 }
      })
    end

    it "ignores the rubric stamp by default" do
      expect(described_class.for(stamped).map(&:kind)).to eq(%w[code_review pattern challenge])
    end

    it "keeps only sections graded under the current rubric when asked" do
      expect(described_class.for(stamped, require_rubric: true).map(&:kind)).to eq(%w[code_review])
    end
  end
end
