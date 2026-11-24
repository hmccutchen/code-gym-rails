require "rails_helper"

RSpec.describe "Authentic PR Review", type: :request do
  let(:user) { create_fake_provider_user(daily_section_count: 2) }

  it "generates, submits, grades, and replays an ordinary progression-eligible review" do
    user.update!(skill_level: "mid_level")
    pin_code_review_mode(:application_code)
    allow(WeightedRoll).to receive(:pick)
      .with(ExerciseSection::CodeReview::PrReview::SELECTION_WEIGHTS).and_return("acceptable")

    GenerateDailyExercisesJob.perform_now(user_id: user.id)
    exercise = user.daily_exercises.sole
    section = exercise.problem_set.fetch("code_review")
    expect(section).to include("review_variant" => "pr_review", "pitched_at" => "mid_level")
    expect(exercise.plan_notes).not_to have_key("pr_review_target")

    login_as(user)
    get root_path
    expect(response.body).to include(section.fetch("question"))
    expect(response.body).not_to include(section.dig("answer_key", "reason"))
    post responses_path, params: { response: {
      answers: { code_review: "Approve. The caller forwards the service outcome, including an unavailable result." },
      section_ratings: { code_review: "right_level" }, submit: "1"
    } }, as: :json
    saved = exercise.daily_response
    expect(saved).to be_submitted

    post review_response_path(saved)
    saved.reload
    expect(saved.ai_review.fetch("code_review")).to include(
      "rating" => "solid", "rubric" => ReviewedSectionResults::RUBRIC_VERSION,
      "comprehension" => be_present, "evidence" => be_present, "disposition" => be_present
    )
    expect(saved.assessed_adaptation_sections).to include("code_review")
    expect(ReviewedSectionResults.for(saved, require_rubric: true).map(&:kind)).to include("code_review")
    expect(user.concept_masteries.find_by!(concept: section.fetch("concept")).last_rating).to eq("solid")

    get history_path
    expect(response.body).not_to include(section.dig("answer_key", "reason"))
  end
end
