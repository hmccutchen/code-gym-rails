require "rails_helper"

RSpec.describe "Response coordination with exercise additions", type: :request do
  let(:user) { create_user_with_key }
  let!(:exercise) do
    user.daily_exercises.create!(date: Date.current, generated_at: Time.current, language: "ruby_rails",
      problem_set: { "code_review" => { "question" => "Review this", "concept" => "n_plus_one" } }, section_order: %w[code_review])
  end
  let(:payload) do
    { response: { draft_scope: exercise.draft_scope, manifest_revision: exercise.active_section_keys.size,
      answers: { code_review: "Use a single query for the related records." }, section_ratings: { code_review: "right_level" }, submit: "1" } }
  end

  before { login_as(user) }

  def addition(status: "queued", **attributes)
    exercise.exercise_additions.create!(request_uuid: SecureRandom.uuid, kind: "pattern", status: status,
      draft_scope: exercise.draft_scope, date: exercise.date, **attributes)
  end

  def draft
    user.daily_responses.create!(daily_exercise: exercise, date: exercise.date,
      answers: { "code_review" => "Keep this original answer" }, section_ratings: { "code_review" => "right_level" })
  end

  it "requires the current manifest revision before creating a submitted response" do
    [ nil, 0, "1junk" ].each do |revision|
      post responses_path, params: payload.deep_merge(response: { manifest_revision: revision }), as: :json
      expect(response).to have_http_status(:conflict)
      expect(response.parsed_body).to include("status" => "manifest_changed", "draft_scope" => exercise.draft_scope, "manifest_revision" => 1)
      expect(exercise.reload.daily_response).to be_nil
    end
  end

  it "requires the shown scope for a new submission" do
    post responses_path, params: payload.deep_merge(response: { draft_scope: nil }), as: :json
    expect(response).to have_http_status(:conflict)
    expect(response.parsed_body["status"]).to eq("stale")
    expect(exercise.reload.daily_response).to be_nil
  end

  it "submits one answered and rated section with a matching revision" do
    post responses_path, params: payload, as: :json
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include("submitted" => true, "draft_scope" => exercise.draft_scope, "manifest_revision" => 1)
  end

  %w[queued running].each do |status|
    it "refuses submission while an addition is #{status}, without changing the draft" do
      saved = draft
      original = saved.attributes
      addition(status: status, claimed_at: status == "running" ? Time.current : nil)

      post responses_path, params: payload, as: :json

      expect(response).to have_http_status(:conflict)
      expect(response.parsed_body).to include("status" => "addition_busy", "manifest_revision" => 1)
      expect(saved.reload.attributes).to eq(original)
    end
  end

  it "rechecks an addition accepted after recovery and before the submit lock" do
    allow(ExerciseAdditionRequest).to receive(:recover!).and_wrap_original do |original, current|
      original.call(current)
      addition
    end

    post responses_path, params: payload, as: :json

    expect(response).to have_http_status(:conflict)
    expect(response.parsed_body["status"]).to eq("addition_busy")
    expect(exercise.reload.daily_response).to be_nil
  end

  it "does not treat an expired lease as permission to submit while recovery is busy" do
    pending = addition(created_at: (DailyExercise::JOB_PICKUP_MARGIN + 1.second).ago)
    allow(ExerciseAdditionRequest).to receive(:recover!).with(exercise).and_return(:busy)

    post responses_path, params: payload, as: :json

    expect(response).to have_http_status(:conflict)
    expect(response.parsed_body["status"]).to eq("addition_busy")
    expect(pending.reload.status).to eq("queued")
    expect(exercise.reload.daily_response).to be_nil
  end

  it "allows autosaves while adding and returns the current revision" do
    addition
    post responses_path, params: payload.deep_merge(response: { submit: "0", manifest_revision: 0 }), as: :json
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include("submitted" => false, "manifest_revision" => 1, "draft_scope" => exercise.draft_scope)
    expect(exercise.reload.daily_response.answers["code_review"]).to eq(payload[:response][:answers][:code_review])
  end

  it "keeps answers from a new card when an older tab autosaves only the original card" do
    saved = draft
    saved.update!(answers: saved.answers.merge("pattern" => "The new card answer"), section_ratings: saved.section_ratings.merge("pattern" => "too_hard"))
    exercise.update!(problem_set: exercise.problem_set.merge("pattern" => { "question" => "Explain the pattern", "concept" => "memoization" }),
      section_order: %w[code_review pattern])

    post responses_path, params: payload.deep_merge(response: { submit: "0", manifest_revision: 1 }), as: :json

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body["manifest_revision"]).to eq(2)
    expect(saved.reload.answers["pattern"]).to eq("The new card answer")
    expect(saved.section_ratings["pattern"]).to eq("too_hard")
  end

  it "refuses a stale tab submit after append without accepting any of its edits" do
    saved = draft
    original = saved.attributes
    exercise.update!(problem_set: exercise.problem_set.merge("pattern" => { "question" => "Explain the pattern" }), section_order: %w[code_review pattern])

    post responses_path, params: payload.deep_merge(response: { manifest_revision: 1 }), as: :json

    expect(response).to have_http_status(:conflict)
    expect(response.parsed_body).to include("status" => "manifest_changed", "manifest_revision" => 2)
    expect(saved.reload.attributes).to eq(original)
  end

  it "rechecks the manifest after the request loaded the set" do
    shown = payload
    allow(ExerciseAdditionRequest).to receive(:recover!).and_wrap_original do |original, current|
      original.call(current)
      exercise.update!(problem_set: exercise.problem_set.merge("pattern" => { "question" => "Explain the pattern" }),
        section_order: %w[code_review pattern])
    end

    post responses_path, params: shown, as: :json

    expect(response).to have_http_status(:conflict)
    expect(response.parsed_body).to include("status" => "manifest_changed", "manifest_revision" => 2)
    expect(exercise.reload.daily_response).to be_nil
  end

  it "keeps submitted retries idempotent without demanding new submission metadata" do
    saved = draft
    saved.update!(submitted_at: Time.current)
    original = saved.attributes

    post responses_path, params: { response: { submit: "1", answers: { code_review: "A stale retry" } } }, as: :json

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include("submitted" => true, "review_url" => review_response_path(saved))
    expect(saved.reload.attributes).to eq(original)
  end

  it "recovers a queued request lost before enqueue before submitting" do
    pending = addition(created_at: (DailyExercise::JOB_PICKUP_MARGIN + 1.second).ago)
    post responses_path, params: payload, as: :json
    expect(response).to have_http_status(:ok)
    expect(pending.reload.status).to eq("failed")
    expect(exercise.reload.daily_response).to be_submitted
  end

  it "blocks Start over without clearing any work during addition" do
    saved = draft
    pending = addition
    scope = exercise.draft_scope

    delete start_over_response_path(saved)

    expect(response).to redirect_to(root_path)
    expect(saved.reload.answers["code_review"]).to eq("Keep this original answer")
    expect(exercise.reload.draft_scope).to eq(scope)
    expect(pending.reload.status).to eq("queued")
  end

  it "recovers an expired request before Start over" do
    saved = draft
    pending = addition(created_at: (DailyExercise::JOB_PICKUP_MARGIN + 1.second).ago)

    delete start_over_response_path(saved)

    expect(response).to redirect_to(root_path)
    expect(DailyResponse.exists?(saved.id)).to be(false)
    expect(pending.reload.status).to eq("failed")
  end

  it "blocks regeneration before taking a regeneration claim" do
    addition
    expect {
      post regenerate_path, params: { draft_scope: exercise.draft_scope }
    }.not_to have_enqueued_job(RegenerateExerciseJob)
    expect(response).to redirect_to(root_path)
    expect(exercise.reload.regenerating_since).to be_nil
  end

  it "recovers an expired request before regeneration" do
    pending = addition(created_at: (DailyExercise::JOB_PICKUP_MARGIN + 1.second).ago)
    expect {
      post regenerate_path, params: { draft_scope: exercise.draft_scope }
    }.to have_enqueued_job(RegenerateExerciseJob)
    expect(pending.reload.status).to eq("failed")
  end
end
