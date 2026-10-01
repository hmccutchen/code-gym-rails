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

  it "keeps an invalid or missing self-rating as it was stored" do
    results = described_class.for(response({
      "code_review" => { rung: "junior", self: nil }, "pattern" => { rung: "junior", self: "meh" }
    }))

    expect(results.map(&:self_rating)).to eq([ nil, "meh" ])
  end

  it "reads nothing from a draft" do
    expect(described_class.for(response({ "code_review" => { rung: "junior" } }, submitted: false))).to eq([])
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
