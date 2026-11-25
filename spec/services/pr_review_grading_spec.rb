require "rails_helper"

RSpec.describe "Submitted PR Review grading" do
  let(:user) { User.create!(email: "pr-reviewer@example.test", provider: "fake", api_keys: { "fake" => "fake-test-key" }) }
  let(:section) do
    {
      "review_variant" => "pr_review", "pitched_at" => "mid_level", "scenario" => "Report the booking service result.",
      "question" => "Trace the behavior and decide how to review the change.",
      "concept" => "service_objects", "requirements" => [ "Report unavailable when there is no slot." ],
      "file_1_path" => "app/services/availability.rb", "file_1_code" => "def available?\n  false\nend", "file_1_changed_lines" => [ 2 ],
      "file_2_path" => "app/controllers/bookings_controller.rb",
      "file_2_code" => "def state\n  available? ? :open : :unavailable\nend", "file_2_changed_lines" => [],
      "answer_key" => {
        "case" => "acceptable", "reason" => "PRIVATE GRADE KEY. It also carries an undisclosed intermediate inference.",
        "behavior" => { "requirement" => 1, "expected" => ":unavailable", "observed" => ":unavailable" },
        "evidence" => [ { "path" => "app/controllers/bookings_controller.rb", "quote" => "available? ? :open : :unavailable" } ]
      }
    }
  end
  let(:exercise) do
    DailyExercise.create!(user: user, date: Date.current, generated_at: Time.current, language: "ruby_rails",
      problem_set: { "code_review" => section, "pattern" => { "scenario" => "Render a page.", "question" => "Explain caching." } })
  end
  let(:response) do
    DailyResponse.create!(user: user, daily_exercise: exercise, date: Date.current, submitted_at: Time.current,
      answers: { "code_review" => "The caller reports unavailable on a false service result. Approve.", "pattern" => "Reuse the result." })
  end
  let(:service) { FakeService.new("fake-key") }
  let(:feedback) do
    {
      "comprehension" => "You traced the service result into the caller.",
      "evidence" => "You backed your conclusion with the false branch.",
      "disposition" => "Your approval fits the available evidence."
    }
  end
  let(:rated_reply) do
    feedback.merge("ungradable" => false, "artifact_case" => "acceptable", "assessment" => "sound", "rating" => "solid")
  end

  def day_context
    service.review_grading_provider.day_context.call("Ruby/Rails", exercise, response)
  end

  def grade(key = "code_review", actor: user, grading_service: service)
    ReviewGrading.grade_section(key, context: day_context, user: actor, exercise: exercise, response: response,
      coach: "Ruby/Rails", provider: grading_service.review_grading_provider).last
  end

  before do
    response.claim_reviewing!
  end

  it "sends the verified key only in the submitted target prompt and keeps the same review purpose" do
    expect(day_context).to include(section.fetch("scenario"), section.fetch("requirements").sole)
    expect(day_context).not_to include("PRIVATE GRADE KEY")
    received = []
    allow(service).to receive(:call_and_log) do |_actor, request|
      received << request
      { text: (request.prompt.include?("Private cross-check for this submitted section only:") ? rated_reply : { "rating" => "solid", "missed" => [] }).to_json }
    end
    allow(FakeService).to receive(:judges_review_prose?).and_return(true)
    expect(service).not_to receive(:judge_review_prose).with(user, ExerciseSection::CodeReview, anything, coach: "Ruby/Rails")
    expect(service).to receive(:judge_review_prose).with(user, ExerciseSection::Pattern, anything, coach: "Ruby/Rails")
      .and_return(ReviewProseVerdict.new(status: :keep))
    stub_env("REVIEW_PROSE_JUDGE" => "1")

    expect(grade).to eq(ok: true, review: feedback.merge("rating" => "solid", "rubric" => ReviewedSectionResults::RUBRIC_VERSION, "ungradable" => false))
    expect(grade("pattern")[:ok]).to be(true)
    target, sibling = received
    expect(target.purpose).to eq("review_response")
    expect(target).to be_sensitive
    expect(sibling).not_to be_sensitive
    expect(target.system).not_to include("PRIVATE GRADE KEY")
    expect(target.prompt).to include("Private cross-check for this submitted section only:", "comprehension", "material blocker")
    expect(target.prompt).not_to include("PRIVATE GRADE KEY")
    expect(sibling.prompt).not_to include("Private cross-check for this submitted section only:", "PRIVATE GRADE KEY")
  end

  it "uses the shared rubric and defines only the essential review gaps in the section prompt" do
    allow(service).to receive(:call_and_log) do |_actor, request|
      expect(request.system).to include(ReviewPrompt::RATING_RUBRIC)
      expect(request.prompt).to include("Use the shared rating rubric", "Treat a missed blocker",
        'Record essential gaps in "evidence" or "disposition".', ConceptMastery::AI_RATING_RANK.keys.to_sentence)
      expect(request.prompt).not_to include("developing at most", "Use beginner", "Use solid", "strong only")
      { text: rated_reply.to_json }
    end

    expect(grade[:ok]).to be(true)
  end

  it "sends only the case and public evidence needed for grading" do
    original = section.fetch("answer_key")
    privacy_probe = "SYNTHETIC PRIVATE OBSERVATION"
    stored = section.merge("answer_key" => original.merge(
      "behavior" => { "requirement" => 1, "expected" => privacy_probe, "observed" => privacy_probe }
    ))
    exercise.update!(problem_set: exercise.problem_set.merge("code_review" => stored))

    expect(service).to receive(:call_and_log) do |_actor, request|
      expect(request.prompt).to include(original.fetch("evidence").sole.fetch("quote"), '"case":"acceptable"')
      expect(request.prompt).not_to include(privacy_probe, "undisclosed intermediate inference", "PRIVATE GRADE KEY")
      { text: rated_reply.to_json }
    end

    expect(grade[:ok]).to be(true)
  end

  it "withholds variant requests from another owner, unsubmitted responses and absent or released claims" do
    expect(service).not_to receive(:call_and_log)
    stranger = User.create!(email: "another-pr-reviewer@example.test")
    expect(grade(actor: stranger)[:ok]).to be(false)
    token = response.reviewing_since
    expect(response.release_reviewing!(token)).to be(true)
    response.reviewing_since = token
    expect(grade[:ok]).to be(false)
    response.update!(submitted_at: nil)
    response.claim_reviewing!
    expect(grade[:ok]).to be(false)
  end

  it "completes a skipped answer without a provider call or rating" do
    response.update!(answers: { "pattern" => "Reuse the result." })
    expect(service).not_to receive(:call_and_log)

    expect(grade).to match(ok: true, review: a_hash_including("ungradable" => false))
    expect(grade.fetch(:review)).not_to have_key("rating")
    expect(grade.fetch(:review)).not_to have_key("rubric")
  end

  it "reports an unusable artifact as ungradable even when its answer was skipped" do
    response.update!(answers: { "pattern" => "Reuse the result." })
    exercise.update!(problem_set: exercise.problem_set.merge("code_review" => section.except("answer_key")))
    expect(service).not_to receive(:call_and_log)

    expect(grade).to match(ok: true, review: a_hash_including("ungradable" => true))
  end

  it "completes a missing or ungrounded stored key as ungradable without sending it" do
    expect(service).not_to receive(:call_and_log)
    [
      section.except("answer_key"),
      section.deep_merge("answer_key" => { "evidence" => [ { "path" => "app/services/availability.rb", "quote" => "foobar" } ] }),
      section.merge("file_1_changed_lines" => [])
    ].each do |invalid|
      exercise.update!(problem_set: exercise.problem_set.merge("code_review" => invalid))
      review = grade.fetch(:review)
      expect(review).to include("ungradable" => true)
      expect(review.keys).not_to include("rating", "rubric")
    end
  end

  it "preserves valid ratings but caps claimed favorable ratings where the response identifies an essential gap" do
    { "sound" => "strong", "essential_gap" => "developing", "main_point_missed" => "beginner" }.each do |assessment, expected_rating|
      allow(service).to receive(:call_and_log).and_return(text: rated_reply.merge("assessment" => assessment, "rating" => "strong").to_json)
      expect(grade.fetch(:review)).to eq(feedback.merge("ungradable" => false, "rating" => expected_rating, "rubric" => ReviewedSectionResults::RUBRIC_VERSION))
    end
  end

  it "completes explicit ungradable and key disagreement without rating or rubric" do
    [ feedback.merge("ungradable" => true), rated_reply.merge("artifact_case" => "flawed") ].each do |raw|
      allow(service).to receive(:call_and_log).and_return(text: raw.to_json)
      review = grade.fetch(:review)
      expect(review).to include("ungradable" => true)
      expect(review.keys).not_to include("rating", "rubric")
    end
  end

  it "withholds transport responses that could echo the private key" do
    claude = ClaudeService.new("sk-ant-test")
    rejected = instance_double(Faraday::Response, success?: false, status: 400, body: '{"error":{"message":"PRIVATE GRADE KEY"}}')
    proxy_error = instance_double(Faraday::Response, success?: true, status: 200, body: "<html>PRIVATE GRADE KEY</html>")
    allow(claude).to receive(:post).and_return(rejected, proxy_error)
    expect(Rails.logger).not_to receive(:error).with(/PRIVATE GRADE KEY/)

    expect(grade(grading_service: claude)).to include(ok: false)
    expect(grade(grading_service: claude)).to include(ok: false)
  end

  it "keeps malformed or failed provider results retryable without saving a rating" do
    [ rated_reply.except("evidence"), rated_reply.merge("rating" => "extra-credit"), rated_reply.merge("ungradable" => "false"),
      rated_reply.merge("evidence" => "") ].each do |raw|
      allow(service).to receive(:call_and_log).and_return(text: raw.to_json)
      expect(grade).to include(ok: false, failure: "other")
    end
    allow(service).to receive(:call_and_log).and_raise(ProviderError::TimeoutError)
    expect(grade).to include(ok: false, failure: "timeout")
  end
end
