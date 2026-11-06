require "rails_helper"

RSpec.describe PracticeEvidence do
  let(:user) { create_user_with_key }

  def response_on(date, rating:, eased: false, self_rating: "right_level")
    exercise = user.daily_exercises.create!(date: date, generated_at: Time.current,
      problem_set: { "pattern" => { "concept" => "memoization", "eased" => eased } })
    user.daily_responses.create!(daily_exercise: exercise, date: date, submitted_at: Time.current,
      answers: { "pattern" => "Use a bounded memoized value." }, section_ratings: { "pattern" => self_rating },
      concept_tags: { "pattern" => "memoization" }, ai_review: { "pattern" => { "rating" => rating } })
  end

  it "keeps struggle through eased comfort and missing feedback, until normal comfortable success" do
    response_on(Date.current - 4, rating: "developing")
    response_on(Date.current - 3, rating: "strong", eased: true)
    response_on(Date.current - 2, rating: "solid", self_rating: nil)
    facts = described_class.for(user, before: Date.current)
    expect(facts[:initial_reviewed_sets]).to eq(2)
    expect(facts[:struggle]["pattern"]).to be(true)
    response_on(Date.current - 1, rating: "solid")
    expect(described_class.for(user, before: Date.current)[:struggle]["pattern"]).to be(false)
  end

  it "counts basic core completion rather than rubric, rung or skipped walkthroughs" do
    partial = response_on(Date.current - 4, rating: "solid")
    partial.daily_exercise.update!(problem_set: partial.daily_exercise.problem_set.merge("code_review" => { "snippet" => "x" }))
    partial.update!(answers: partial.answers.merge("code_review" => "A pending answer"))
    bug = response_on(Date.current - 3, rating: "solid")
    bug.daily_exercise.update!(problem_set: { "code_review" => { "purpose" => "Find the trap" } })
    bug.update!(answers: { "code_review" => "Find the bug" }, ai_review: { "code_review" => { "rating" => "solid" } })
    skipped = response_on(Date.current - 2, rating: "solid")
    skipped.daily_exercise.update!(problem_set: skipped.daily_exercise.problem_set.merge("code_review" => { "snippet" => "x" }))
    expect(described_class.for(user, before: Date.current)[:initial_reviewed_sets]).to eq(1)
    partial.update!(ai_review: partial.ai_review.merge("code_review" => { "rating" => "developing" }))
    expect(described_class.for(user, before: Date.current)[:initial_reviewed_sets]).to eq(2)
  end

  it "reads one bounded string gap only from the owner's matching assessed source" do
    response = response_on(Date.yesterday, rating: "developing")
    response.update!(ai_review: response.ai_review.deep_merge("pattern" => { "missed" => [ "x" * 500, "SECOND SECRET" ] }))
    row = user.concept_masteries.create!(concept: "memoization", language: "ruby_rails", practice_requests: {
      "pattern" => { "mode" => "simplified", "source_response_id" => response.id, "requested_at" => Time.current.utc.iso8601(6) }
    })
    expect(described_class.pending_for(user).sole[:gap]).to eq("x" * described_class::GAP_LIMIT)
    response.update!(ai_review: response.ai_review.deep_merge("pattern" => { "missed" => [ { "secret" => "object" } ] }))
    expect(described_class.pending_for(user).sole[:gap]).to be_nil
    other = create_user_with_key(email: "practice-gap-other@example.com")
    row.update!(user: other)
    expect(described_class.pending_for(other).sole[:gap]).to be_nil
  end
end
