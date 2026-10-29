require "rails_helper"
require Rails.root.join("script/key_sheet_export")

RSpec.describe KeySheetExport do
  let(:user) { User.create!(email: "sheet@example.com", name: "Sheet") }
  let(:key) { { "issue" => "`order.customer` per row", "why_it_matters" => "w", "fix" => "f" } }
  let(:code_review) do
    { "question" => "What is wrong?", "scenario" => "orders page", "snippet" => "orders.each { |order| order.customer }",
      "current_schema" => "t.bigint :customer_id", "concept" => "n_plus_one", "answer_key" => key }
  end

  def day(date, sections, reviews: sections.keys, submitted: true, language: "ruby_rails")
    exercise = DailyExercise.create!(user: user, date: date, generated_at: Time.current, language: language, problem_set: sections)
    DailyResponse.create!(user: user, daily_exercise: exercise, date: date, submitted_at: (Time.current if submitted),
                          answers: sections.keys.index_with { "ANSWER-SENTINEL" },
                          section_ratings: sections.keys.index_with { "right_level" },
                          ai_review: reviews.index_with { { "rating" => "RATING-SENTINEL", "missed" => [ "REVIEW-SENTINEL" ] } })
  end

  it "lists each reviewed keyed section with what the key quotes and the key, and nothing about the engineer" do
    day(Date.new(2026, 10, 20), { "code_review" => code_review })

    sheet = described_class.new(user_id: user.id).call

    expect(sheet["sections"]).to eq([ { "kind" => "code_review", "language" => "ruby_rails", "scenario" => "orders page",
                                        "question" => "What is wrong?",
                                        "shown" => { "snippet" => code_review["snippet"], "current_schema" => "t.bigint :customer_id" },
                                        "answer_key" => key } ])
    expect(sheet.to_json).not_to include("SENTINEL", "2026-10-20", "right_level")
  end

  it "shows a multi-file code review's files, the code its key quotes" do
    section = CodeReviewMultiFile::SECTION

    expect(described_class.entry("code_review", "ruby_rails", section)["shown"])
      .to eq(section.slice("file_1_code", "file_2_code"))
  end

  it "leaves out unreviewed, unsubmitted, keyless and non-keyed sections" do
    day(Date.new(2026, 10, 18), { "code_review" => code_review }, reviews: [])
    day(Date.new(2026, 10, 19), { "code_review" => code_review }, submitted: false)
    day(Date.new(2026, 10, 20), { "code_review" => code_review.except("answer_key"),
                                  "pattern" => { "question" => "q", "concept" => "service_objects" } })

    expect(described_class.new(user_id: user.id).call["sections"]).to be_empty
  end

  it "takes the newest sections of each kind up to the per-kind limit" do
    plan = { "question" => "Approve?", "plan_excerpt" => "Cache for `300` seconds.", "concept" => "scope_creep",
             "answer_key" => { "flaws" => [ { "flaw" => "`300`", "pushback" => "Why?" } ] } }
    day(Date.new(2026, 10, 18), { "code_review" => code_review.merge("question" => "oldest") })
    day(Date.new(2026, 10, 19), { "code_review" => code_review.merge("question" => "middle"), "plan_review" => plan })
    day(Date.new(2026, 10, 20), { "code_review" => code_review.merge("question" => "newest") })

    sections = described_class.new(user_id: user.id, per_kind: 2).call["sections"]

    expect(sections.map { |entry| [ entry["kind"], entry["question"] ] })
      .to eq([ %w[code_review newest], %w[code_review middle], %w[plan_review Approve?] ])
    expect(sections.last["shown"]).to eq("plan_excerpt" => "Cache for `300` seconds.")
  end

  it "samples each language separately, so newer days in one can't crowd out the other" do
    day(Date.new(2026, 10, 18), { "code_review" => code_review.merge("question" => "ruby") })
    day(Date.new(2026, 10, 19), { "code_review" => code_review.merge("question" => "js one") }, language: "javascript")
    day(Date.new(2026, 10, 20), { "code_review" => code_review.merge("question" => "js two") }, language: "javascript")

    sections = described_class.new(user_id: user.id, per_kind: 1).call["sections"]

    expect(sections.map { |entry| entry.values_at("language", "question") }).to eq([ [ "javascript", "js two" ], %w[ruby_rails ruby] ])
  end

  it "reads inside the read-only transaction" do
    allow(ReviewBaselineExport).to receive(:read_only).and_call_original

    described_class.new(user_id: user.id).call

    expect(ReviewBaselineExport).to have_received(:read_only)
  end
end
