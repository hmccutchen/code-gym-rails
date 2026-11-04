require "rails_helper"
require Rails.root.join("script/code_review_split")

RSpec.describe CodeReviewSplit do
  let(:user) { User.create!(email: "split@example.com", name: "Split") }
  let(:out) { StringIO.new }
  let(:single) { { "snippet" => "x = 1", "question" => "q", "pitched_at" => "mid_level", "answer_key" => { "issue" => "SECRET" } } }
  let(:multi) { FakeService::MULTI_FILE_CODE_REVIEW.deep_dup.merge("pitched_at" => "mid_level", "file_1_changed_lines" => [ 4 ]) }
  let(:bug_hunt) { single.merge("purpose" => "Adds one.") }

  def reviewed(section, rating:, answer: "My answer.", date: Date.current - DailyResponse.count)
    exercise = DailyExercise.create!(user: user, date: date, generated_at: Time.current, language: "ruby_rails",
                                     problem_set: { "code_review" => section })
    DailyResponse.create!(user: user, daily_exercise: exercise, date: date, submitted_at: Time.current,
                          answers: { "code_review" => answer }, ai_review: { "code_review" => { "rating" => rating } })
  end

  it "counts reviewed results by shape and rung, with each rating, and prints no answer, key or account" do
    reviewed(single, rating: "solid")
    reviewed(single, rating: "strong")
    reviewed(multi, rating: "developing")
    reviewed(multi.merge("pitched_at" => "senior"), rating: "beginner")
    reviewed(bug_hunt, rating: "solid")
    reviewed(single, rating: "solid", answer: "")

    expect { described_class.new(out: out).report }.not_to change { [ DailyExercise.count, DailyResponse.count, ApiUsage.count ] }

    expect(out.string).to include(
      "single mid_level: 3 (beginner 0, developing 0, solid 1, strong 1, unrated 1)",
      "multi mid_level: 1 (beginner 0, developing 1, solid 0, strong 0, unrated 0)",
      "multi senior: 1 (beginner 1, developing 0, solid 0, strong 0, unrated 0)",
      "bug_hunt mid_level: 1 (beginner 0, developing 0, solid 1, strong 0, unrated 0)"
    )
    expect(out.string).not_to include("SECRET", "My answer", user.email, "orders.sum")
  end

  it "leaves out a submitted day that has no review yet" do
    exercise = DailyExercise.create!(user: user, date: Date.current, generated_at: Time.current, language: "ruby_rails",
                                     problem_set: { "code_review" => single })
    DailyResponse.create!(user: user, daily_exercise: exercise, date: Date.current, submitted_at: Time.current,
                          answers: { "code_review" => "a" })

    described_class.new(out: out).report

    expect(out.string).to include("reviewed code_review results: 0")
  end

  it "counts the multi-file key notes in the log it is given, by outcome, and nothing else from the log" do
    log = [
      "[planted_key] answer_key=ok kind=code_review language=ruby_rails attempt=draft code_review_mode=test_file code_review_files=multi user=1",
      "[planted_key] answer_key=files_unmatched kind=code_review language=ruby_rails attempt=draft code_review_mode=test_file code_review_files=multi user=1",
      "[planted_key] answer_key=evidence_unlocated kind=code_review language=javascript attempt=retry code_review_mode=application_code code_review_files=multi user=1",
      "[planted_key] answer_key=evidence_unlocated kind=code_review language=ruby_rails attempt=draft code_review_mode=application_code code_review_files=multi user=1",
      "[planted_key] answer_key=quote_missing kind=code_review language=ruby_rails attempt=draft code_review_mode=test_file code_review_files=single user=1",
      "[planted_key] answer_key=missing kind=plan_review language=ruby_rails attempt=draft code_review_mode=test_file code_review_files=multi user=1",
      "[planted_key] answer_key=missing kind=code_review language=ruby_rails attempt=draft code_review_mode=test_file user=1",
      "[retention] user=1 something else"
    ]

    described_class.new(out: out, log_lines: log).report

    expect(out.string).to include("multi-file code_review key notes: 4 (evidence_unlocated 2, files_unmatched 1, ok 1)")
  end

  it "names every outcome the log holds, so the counts always add up to the total" do
    log = [ "[planted_key] answer_key=a_new_reason kind=code_review language=ruby_rails attempt=draft code_review_mode=test_file " \
            "code_review_files=multi user=1" ]

    described_class.new(out: out, log_lines: log).report

    expect(out.string).to include("multi-file code_review key notes: 1 (a_new_reason 1)")
  end

  it "reads the lines GenerationDiagnostics writes" do
    lines = []
    allow(Rails.logger).to receive(:info) { |message| lines << message.to_s }
    note = ProblemSetIngest::KeyNote.new(key: "code_review", language: "ruby_rails", outcome: "evidence_unlocated", quotes: nil)
    GenerationDiagnostics.new(user).key_notes([ note ], attempt: "draft", code_review_mode: :test_file, code_review_files: 2..3)

    described_class.new(out: out, log_lines: lines).report

    expect(out.string).to include("multi-file code_review key notes: 1 (evidence_unlocated 1)")
  end

  it "says when it was given no log" do
    described_class.new(out: out).report

    expect(out.string).to include("multi-file code_review key notes: no log given")
  end
end
