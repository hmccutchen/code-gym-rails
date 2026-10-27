require "rails_helper"
require Rails.root.join("script/review_baseline_export")

RSpec.describe ReviewBaselineExport do
  let(:user) { User.create!(email: "baseline@example.com", name: "Baseline") }
  let(:stamp) { ReviewedSectionResults::RUBRIC_VERSION }
  let(:parsons_blocks) { %w[first second third] }

  def reviewed_day(date, sections, owner: user, submitted: true)
    exercise = DailyExercise.create!(
      user: owner, date: date, generated_at: Time.current, language: "ruby_rails",
      problem_set: sections.transform_values { |section| section.fetch(:data, { "question" => "q", "snippet" => "s", "pitched_at" => "senior" }) }
    )
    DailyResponse.create!(
      user: owner, daily_exercise: exercise, date: date, submitted_at: (Time.current if submitted),
      answers: sections.transform_values { |section| section.fetch(:answer, "Add includes(:customer).") },
      section_ratings: sections.transform_values { "right_level" },
      ai_review: sections.transform_values { |section| section.fetch(:review, { "rating" => "developing", "missed" => [ "m" ], "essential_gaps" => [ 0 ], "rubric" => stamp }) }
    )
  end

  def exported_kinds(payload) = payload["days"].flat_map { |day| day["sections"].map { |stored| [ day["date"], stored["kind"] ] } }

  it "exports each answered, rubric-stamped, grader-rated section with its problem, answer, stored rating and gaps" do
    reviewed_day(Date.new(2026, 10, 20), {
      "code_review" => {},
      "parsons_problem" => { data: { "blocks" => parsons_blocks, "pitched_at" => "junior" }, answer: "order:0,1,2" },
      "pattern" => { answer: "" },
      "challenge" => { review: { "rating" => "solid", "missed" => [] } }
    })

    payload = described_class.new(user_id: user.id).call
    day     = payload["days"].sole

    expect(day["sections"]).to eq([
      { "kind" => "code_review", "pitched_at" => "senior", "answer" => "Add includes(:customer).",
        "rating" => "developing", "missed" => [ "m" ], "essential_gaps" => [ 0 ] }
    ])
    expect(day["problem_set"]).to include("code_review", "parsons_problem", "pattern", "challenge")
    expect(day.keys).to include("answers", "section_ratings", "pseudocode_rounds", "plan_notes", "language", "review_provider")
    expect(payload).to include("format" => described_class::FORMAT, "rubric" => stamp)
  end

  it "leaves out unsubmitted days and other accounts" do
    reviewed_day(Date.new(2026, 10, 20), { "code_review" => {} }, submitted: false)
    reviewed_day(Date.new(2026, 10, 20), { "code_review" => {} }, owner: User.create!(email: "other@example.com", name: "Other"))

    expect(described_class.new(user_id: user.id).call["days"]).to be_empty
  end

  it "takes the newest sections first and stops at the limit, inside a day if it has to" do
    reviewed_day(Date.new(2026, 10, 19), { "code_review" => {} })
    reviewed_day(Date.new(2026, 10, 20), { "code_review" => {}, "challenge" => {} })

    payload = described_class.new(user_id: user.id, limit: 2).call

    expect(exported_kinds(payload)).to eq([ %w[2026-10-20 code_review], %w[2026-10-20 challenge] ])
    expect(exported_kinds(described_class.new(user_id: user.id, limit: 1).call)).to eq([ %w[2026-10-20 code_review] ])
  end

  it "exports the missed list and gaps the grader wrote when the prose judge reworded them" do
    reviewed_day(Date.new(2026, 10, 20), { "code_review" => { review: {
      "rating" => "developing", "missed" => [ "reworded" ], "rubric" => stamp,
      ReviewProseVerdict::ORIGINAL_KEY => { "missed" => [ "as graded", "second" ], "essential_gaps" => [ 1 ] }
    } } })

    stored = described_class.new(user_id: user.id).call["days"].sole["sections"].sole

    expect(stored).to include("missed" => [ "as graded", "second" ], "essential_gaps" => [ 1 ])
  end

  it "refuses any write inside its read-only transaction" do
    expect { described_class.read_only { User.create!(email: "write@example.com", name: "Write") } }
      .to raise_error(ActiveRecord::StatementInvalid, /read-only transaction/)
  end

  it "rebuilds the export as unsaved records that answer and grade the way the stored day did" do
    reviewed_day(Date.new(2026, 10, 20), { "code_review" => {}, "pattern" => { answer: "" } })
    payload = JSON.parse(JSON.generate(described_class.new(user_id: user.id).call))

    entry = described_class.entries(payload).sole

    expect(entry).to have_attributes(date: Date.new(2026, 10, 20), section: "code_review", rung: "senior", stored_rating: "developing")
    expect(entry.response).to be_new_record
    expect(entry.response.answer_for("code_review")).to eq("Add includes(:customer).")
    expect(entry.response.answered?("pattern")).to be(false)
    expect(entry.exercise.active_section_keys).to eq(%w[code_review pattern])
  end

  it "refuses an export in a format it does not read" do
    expect { described_class.entries({ "format" => described_class::FORMAT + 1, "days" => [] }) }.to raise_error(ArgumentError, /format/)
  end

  it "summarizes an export by kind and reviewing provider, with no answer text" do
    reviewed_day(Date.new(2026, 10, 20), { "code_review" => {}, "challenge" => {} })

    summary = described_class.summary(described_class.new(user_id: user.id).call)

    expect(summary).to eq("exported 2 sections from 1 days · challenge 1, code_review 1 · reviewed by: unrecorded 1")
    expect(summary).not_to include("includes(:customer)")
  end
end
