require "rails_helper"

RSpec.describe "Additional exercise requests", type: :request do
  let(:user) { create_fake_provider_user }
  let(:json) { { "Content-Type" => "application/json", "Accept" => "application/json" } }
  let!(:exercise) do
    user.daily_exercises.create!(date: Date.current, language: "ruby_rails", generated_at: Time.current,
      problem_set: { "pattern" => FakeService::EXERCISE_PROBLEM_SET.fetch("pattern") }, section_order: %w[pattern])
  end

  before { login_as(user) }

  def body = response.parsed_body

  def status(scope: exercise.draft_scope, revision: 1)
    get exercise_additions_path, params: { draft_scope: scope, revision: revision }, headers: json
  end

  it "returns only newly appended cards without keys or old answer HTML" do
    content = FakeService::EXERCISE_PROBLEM_SET.fetch("code_review").deep_dup
    content["answer_key"] = { "issue" => "PRIVATE-ADDITION-KEY", "why_it_matters" => "secret", "fix" => "secret" }
    exercise.update!(problem_set: exercise.problem_set.merge("code_review" => content), section_order: %w[pattern code_review])

    status

    expect(response).to have_http_status(:ok)
    expect(body).to include("draft_scope" => exercise.draft_scope, "manifest_revision" => 2,
      "section_keys" => %w[pattern code_review], "submitted" => false)
    expect(body.fetch("cards").keys).to eq(%w[code_review])
    expect(body.fetch("cards").fetch("code_review")).to include('data-section-fold="code_review"')
    expect(response.body).not_to include("PRIVATE-ADDITION-KEY")
  end

  it "returns the response authority's answered sections with appended cards" do
    exercise.update!(problem_set: exercise.problem_set.merge("code_review" => FakeService::EXERCISE_PROBLEM_SET.fetch("code_review")),
      section_order: %w[pattern code_review])
    saved = exercise.create_daily_response!(user: user, date: exercise.date,
      answers: { "pattern" => "", "code_review" => "Move the query outside the loop." },
      section_ratings: { "code_review" => "right_level" })

    status

    expect(body.fetch("answered_sections")).to eq(saved.answered_sections)
    expect(body.fetch("submit_blocker")).to eq(saved.submit_blocker)
    expect(body.fetch("answered_sections")).to eq(%w[code_review])
  end

  it "does not render obsolete cards for another scope" do
    status(scope: "#{exercise.id}-1", revision: 0)

    expect(response).to have_http_status(:conflict)
    expect(body).not_to have_key("cards")
  end

  it "does not render another account's set" do
    other = create_fake_provider_user
    other_set = other.daily_exercises.create!(date: Date.current, generated_at: Time.current, problem_set: { "pattern" => {} })

    status(scope: other_set.draft_scope, revision: 0)

    expect(response).to have_http_status(:conflict)
    expect(body).not_to have_key("cards")
  end

  it "reports an expired operation without changing its status or enqueueing a job" do
    addition = exercise.exercise_additions.create!(request_uuid: SecureRandom.uuid, kind: "code_review",
      date: Date.current, draft_scope: exercise.draft_scope, status: "queued", created_at: 2.days.ago)

    expect { status }.not_to have_enqueued_job

    expect(body.fetch("operation")).to include("request_uuid" => addition.request_uuid, "status" => "queued", "expired" => true)
    expect(addition.reload.status).to eq("queued")
  end

  it "accepts an Add without changing the learner's preferences" do
    original = user.attributes.slice("daily_section_kinds", "section_kind_weights", "excluded_section_kinds")
    uuid = SecureRandom.uuid

    post exercise_additions_path, params: { request_uuid: uuid, kind: "code_review",
      draft_scope: exercise.draft_scope, revision: 1 }.to_json, headers: json

    expect(response).to have_http_status(:accepted)
    expect(body.fetch("operation")).to include("request_uuid" => uuid, "kind" => "code_review", "status" => "queued")
    expect(user.reload.attributes.slice(*original.keys)).to eq(original)
  end

  it "rejects a malformed revision instead of returning existing cards" do
    status(revision: "not-a-revision")

    expect(response).to have_http_status(:unprocessable_content)
    expect(body).not_to have_key("cards")
  end

  it "moves only the shown paused set on Add while polling leaves its date alone" do
    allow(HeldSetLookup).to receive(:enabled?).and_return(true)
    user.update!(paused_generation_at: 3.days.ago)
    exercise.update!(date: Date.yesterday)
    original_scope = exercise.draft_scope

    status(scope: original_scope)
    expect(exercise.reload.date).to eq(Date.yesterday)

    post exercise_additions_path, params: { request_uuid: SecureRandom.uuid, kind: "code_review",
      draft_scope: "#{exercise.id}-1", revision: 1 }.to_json, headers: json
    expect(response).to have_http_status(:conflict)
    expect(exercise.reload.date).to eq(Date.yesterday)

    post exercise_additions_path, params: { request_uuid: SecureRandom.uuid, kind: "code_review",
      draft_scope: original_scope, revision: 1 }.to_json, headers: json

    expect(response).to have_http_status(:accepted)
    expect(exercise.reload.date).to eq(Date.current)
    expect(exercise.exercise_additions.sole.date).to eq(Date.current)
  end

  it "rejects a malformed request identity without enqueueing paid work" do
    expect do
      post exercise_additions_path, params: { request_uuid: "invalid", kind: "code_review",
        draft_scope: exercise.draft_scope, revision: 1 }.to_json, headers: json
    end.not_to have_enqueued_job

    expect(response).to have_http_status(:unprocessable_content)
    expect(body.fetch("status")).to eq("invalid")
    expect(exercise.exercise_additions).to be_empty
  end

  describe "mapping acceptance outcomes" do
    def request_addition
      post exercise_additions_path, params: { request_uuid: SecureRandom.uuid, kind: "code_review",
        draft_scope: exercise.draft_scope, revision: 1 }.to_json, headers: json
    end

    { accepted: 202, replayed: 200, not_current: 404, deleted: 404, stale: 409,
      invalid: 422, manifest_changed: 409, submitted: 409, busy: 409,
      key_required: 422, unavailable: 409, failed: 503 }.each do |outcome, code|
      it "maps #{outcome} to HTTP #{code}" do
        allow(ExerciseAdditionRequest).to receive(:call).and_return(
          ExerciseAdditionRequest::Outcome.new(status: outcome, addition: nil))

        request_addition

        expect(response.status).to eq(code)
        if %i[accepted replayed].include?(outcome)
          expect(body.fetch("draft_scope")).to eq(exercise.draft_scope)
        else
          expect(body.fetch("error")).to be_present
        end
        expect(body).not_to have_key("cards") if %i[not_current deleted stale].include?(outcome)
      end
    end

    it "raises for an unknown outcome instead of hiding a missing mapping" do
      allow(ExerciseAdditionRequest).to receive(:call).and_return(
        ExerciseAdditionRequest::Outcome.new(status: :unknown, addition: nil))

      expect { request_addition }.to raise_error(ArgumentError, /Unhandled addition outcome/)
    end
  end

  it "refuses a future manifest revision without returning cards" do
    status(revision: 4)

    expect(response).to have_http_status(:conflict)
    expect(body).not_to have_key("cards")
  end
end
