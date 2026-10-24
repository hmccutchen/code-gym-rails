require "rails_helper"

RSpec.describe DailyResponse, ".with_ai_ratings_only" do
  let(:user) { User.create!(email: "ratings-only@example.com", name: "Ratings", language: "ruby_rails") }
  let(:prose) { "The fix still loads every line item before filtering by status. " * 40 }
  let(:full_review) do
    { "rating" => "solid", "correct" => [ prose ], "missed" => [ prose ], "next_step" => prose, "improved_code" => prose,
      "difficulty" => { "level" => "moderate", "reason" => prose } }
  end

  def respond(day, ai_review)
    exercise = DailyExercise.create!(user: user, date: Date.new(2026, 3, day), problem_set: { "code_review" => { "question" => "Q" } },
                                     generated_at: Time.current)
    user.daily_responses.create!(daily_exercise: exercise, date: exercise.date, submitted_at: Time.current, ai_review: ai_review)
  end

  def projected(response) = described_class.where(id: response.id).with_ai_ratings_only(*described_class.column_names).take!

  def rating_or_error(response, section)
    response.ai_rating_for(section)
  rescue StandardError => e
    e.class
  end

  it "keeps only each section's rating and passes every other shape through unchanged" do
    stored = {
      "code_review"       => full_review,
      "design_comparison" => full_review.except("rating"),
      "pattern"           => full_review.merge("rating" => nil),
      "architecture"      => nil,
      "parsons_problem"   => "flattened",
      "security_review"   => [ "listed" ]
    }
    response = respond(2, stored)

    expect(projected(response).ai_review).to eq(
      "code_review" => { "rating" => "solid" }, "design_comparison" => {}, "pattern" => { "rating" => nil },
      "architecture" => nil, "parsons_problem" => "flattened", "security_review" => [ "listed" ]
    )
    stored.each_key { |section| expect(rating_or_error(projected(response), section)).to eq(rating_or_error(response, section)) }
  end

  it "answers whether the day and each section were reviewed as the stored review does" do
    response = respond(2, { "code_review" => full_review, "design_comparison" => full_review.except("rating"), "parsons_problem" => "flattened" })
    sections = %w[code_review design_comparison parsons_problem pattern]

    expect(projected(response).reviewed?).to eq(response.reviewed?)
    expect(sections.map { |section| projected(response).section_reviewed?(section) })
      .to eq(sections.map { |section| response.section_reviewed?(section) })
  end

  it "keeps a missing, empty or malformed review as it was stored" do
    [ nil, {}, "flattened", [ "listed" ], 3 ].each_with_index do |stored, index|
      response = respond(2 + index, stored)

      expect(projected(response).ai_review).to eq(stored)
      expect(rating_or_error(projected(response), "code_review")).to eq(rating_or_error(response, "code_review"))
    end
  end

  it "loads none of the review prose" do
    respond(2, { "code_review" => full_review, "pattern" => full_review })

    expect(described_class.with_ai_ratings_only(:ai_review).take!.ai_review.to_json).not_to include("line item")
  end

  it "returns read-only rows, so a projected review is never saved over the stored one" do
    response = respond(2, { "code_review" => full_review })
    row = projected(response)

    expect(row).to be_readonly
    expect { row.update!(section_ratings: { "code_review" => "too_hard" }) }.to raise_error(ActiveRecord::ReadOnlyRecord)
    expect(response.reload.ai_review).to eq("code_review" => full_review)
  end

  it "selects the stored review column only through the projection" do
    respond(2, { "code_review" => full_review })
    result = described_class.connection.select_all(described_class.with_ai_ratings_only(*described_class.column_names).to_sql)

    expect(result.columns.tally).to eq(described_class.column_names.tally)
    expect(result.first["ai_review"]).not_to include("line item")
  end

  it "loads only the columns asked for, with the projected review added" do
    respond(2, { "code_review" => full_review })
    row = described_class.with_ai_ratings_only(:id, :answers, :ai_review).take!

    expect(row.attributes.keys).to contain_exactly("id", "answers", "ai_review")
    expect(row.ai_review).to eq("code_review" => { "rating" => "solid" })
  end

  it "asks for the columns to load" do
    expect { described_class.with_ai_ratings_only }.to raise_error(ArgumentError)
  end

  it "refuses a column the table does not have" do
    expect { described_class.with_ai_ratings_only(:id, :not_a_column) }.to raise_error(ArgumentError, /not_a_column/)
  end

  it "keeps the scope it is chained onto" do
    other = User.create!(email: "ratings-other@example.com", name: "Other", language: "ruby_rails")
    mine = respond(2, { "code_review" => full_review })
    other_exercise = DailyExercise.create!(user: other, date: mine.date, problem_set: { "code_review" => { "question" => "Q" } }, generated_at: Time.current)
    other.daily_responses.create!(daily_exercise: other_exercise, date: mine.date, submitted_at: Time.current, ai_review: {})
    newer = respond(3, {})

    expect(user.daily_responses.order(date: :desc).with_ai_ratings_only(:id).map(&:id)).to eq([ newer.id, mine.id ])
  end
end
