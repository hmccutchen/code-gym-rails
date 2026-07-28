require "rails_helper"

RSpec.describe "GET /dashboard/status", type: :request do
  let(:user) { create_user_with_key }

  before { login_as(user) }

  it "returns ready when today's exercise exists" do
    DailyExercise.create!(user: user, date: Date.current,
                          problem_set: { "code_review" => {} }, generated_at: Time.current)

    get dashboard_status_path

    expect(response).to have_http_status(:ok)
    expect(JSON.parse(response.body)).to eq("status" => "ready")
  end

  it "returns pending when there's no exercise and no persisted failure" do
    get dashboard_status_path

    expect(JSON.parse(response.body)).to eq("status" => "pending")
  end

  it "returns failed with the persisted message when today's generation failed" do
    user.update!(last_generation_error_date: Date.current,
                 last_generation_error: "The AI provider is rate-limiting requests — try again shortly.")

    get dashboard_status_path

    expect(JSON.parse(response.body)).to eq(
      "status" => "failed",
      "message" => "The AI provider is rate-limiting requests — try again shortly."
    )
  end

  it "returns pending, not failed, when the persisted failure is from a prior day" do
    user.update!(last_generation_error_date: Date.current - 1, last_generation_error: "stale")

    get dashboard_status_path

    expect(JSON.parse(response.body)).to eq("status" => "pending")
  end

  it "returns ready, not failed, once generation succeeds after an earlier failure today" do
    user.update!(last_generation_error_date: Date.current, last_generation_error: "stale")
    DailyExercise.create!(user: user, date: Date.current,
                          problem_set: { "code_review" => {} }, generated_at: Time.current)

    get dashboard_status_path

    expect(JSON.parse(response.body)).to eq("status" => "ready")
  end

  it "returns pending, not failed, while a retry is in flight after an earlier failure today" do
    user.update!(last_generation_error_date: Date.current, last_generation_error: "boom")

    post generate_path

    get dashboard_status_path

    expect(JSON.parse(response.body)).to eq("status" => "pending")
  end
end
