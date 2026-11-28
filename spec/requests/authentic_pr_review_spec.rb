require "rails_helper"

RSpec.describe "Authentic PR Review", type: :request do
  let(:user) { create_fake_provider_user(daily_section_count: 2) }

  it "generates, submits, grades, and replays an ordinary progression-eligible review" do
    user.update!(skill_level: "mid_level")
    pin_code_review_mode(:application_code)
    allow(WeightedRoll).to receive(:pick).with(DailyKinds::DEFAULT.index_with { KindPreferences::DEFAULT_MULTIPLIER })
      .and_return(ExerciseSection::CodeReview)
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
    card = Nokogiri::HTML5(response.body).at_css('[data-section-fold="code_review"]')
    expect(card.css(".kind-about")).to be_empty
    expect(response.body).not_to include(section.dig("answer_key", "reason"))
    post responses_path, params: { response: {
      answers: { code_review: "Approve. The caller forwards the service outcome, including an unavailable result." },
      section_ratings: { code_review: "right_level" }, draft_scope: exercise.draft_scope, manifest_revision: exercise.manifest_revision, submit: "1"
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
  it "grounds both review follow-up actions in the saved public feedback" do
    exercise = user.daily_exercises.create!(date: Date.current, generated_at: Time.current, language: "ruby_rails",
      problem_set: { "code_review" => { "review_variant" => "pr_review", "question" => "Review the change.",
        "answer_key" => { "reason" => "PRIVATE KEY SENTINEL" } } })
    saved = user.daily_responses.create!(daily_exercise: exercise, date: exercise.date, submitted_at: Time.current,
      answers: { "code_review" => "Approve because the service result is passed through." },
      ai_review: { "code_review" => { "rating" => "solid",
        "comprehension" => "You traced the caller.", "evidence" => "The result supports the claim.",
        "disposition" => "Approval fits the requirement.", "artifact_case" => "PRIVATE CASE SENTINEL" } })
    login_as(user)
    service = FakeService.new("fake-test-key")
    allow(AiService).to receive(:for).with(user).and_return(service)

    requests = []
    allow(service).to receive(:call_and_log) do |_actor, request|
      requests << request
      { text: "The caller preserves the result." }
    end

    post follow_ups_response_path(saved), params: { section: "code_review", question: "Why does that support approval?" }, as: :json
    expect(response).to have_http_status(:ok)
    post explain_differently_response_path(saved), params: { section: "code_review" }, as: :json
    expect(response).to have_http_status(:ok)

    expect(requests.map(&:purpose)).to eq(%w[review_follow_up explain_differently])
    requests.each do |request|
      context = [ request.system, request.prompt ].join("\n")
      expect(context).to include("Comprehension: You traced the caller.", "Evidence: The result supports the claim.",
        "Disposition: Approval fits the requirement.")
      expect(context).not_to include("PRIVATE KEY SENTINEL", "PRIVATE CASE SENTINEL",
        "What they missed:", "(no detail recorded)")
    end
  end
end
