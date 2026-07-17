require "rails_helper"

RSpec.describe "Per-user timezone", type: :request do
  include ActiveSupport::Testing::TimeHelpers

  # 2026-07-18 02:30 UTC == 2026-07-17 19:30 America/Los_Angeles:
  # a NEW UTC day but the SAME local (Friday) day.
  let(:instant) { Time.utc(2026, 7, 18, 2, 30) }
  let(:pacific) { create_user_with_key(email: "pac@example.com", name: "Pac", time_zone: "America/Los_Angeles") }

  # Full problem_set — the dashboard partial renders all three sections
  # unconditionally, so a minimal fixture would blow up on nil["title"].
  let(:full_problem_set) do
    {
      "code_review" => { "question" => "Find the bug", "snippet" => "def a; end" },
      "pattern" => {
        "title" => "Service Objects", "why" => "Because", "question" => "When?",
        "reference" => { "tagline" => "T", "explanation" => "E",
                         "code_example" => "code", "senior_lens" => "S" }
      },
      "challenge" => { "title" => "Build", "question" => "Implement X", "starter_code" => "" }
    }
  end

  it "resolves 'today' on the user's local day, not the UTC day" do
    travel_to(instant) do
      local_today = Time.use_zone("America/Los_Angeles") { Date.current } # 2026-07-17
      DailyExercise.create!(user: pacific, date: local_today,
                            problem_set: full_problem_set, generated_at: Time.current)
      login_as(pacific)

      get root_path

      # Dashboard found the local-day exercise; it did not enqueue a new generation.
      expect(response).to have_http_status(:ok)
      expect(DailyExercise.where(user: pacific).count).to eq(1)
    end
  end

  it "saves a submitted response under the local date across UTC midnight (lost-work regression)" do
    travel_to(instant) do
      local_today = Time.use_zone("America/Los_Angeles") { Date.current } # 2026-07-17
      exercise = DailyExercise.create!(user: pacific, date: local_today,
                                       problem_set: { "code_review" => {} }, generated_at: Time.current)
      login_as(pacific)

      post responses_path,
           params: { response: { answers: { code_review: "x" * 20 }, submit: "1" } }.to_json,
           headers: { "Content-Type" => "application/json", "Accept" => "application/json" }

      expect(response).to have_http_status(:ok)
      resp = pacific.daily_responses.sole
      # Under the old UTC behavior this would be 2026-07-18; the fix keeps it local.
      expect(resp.date).to eq(Date.new(2026, 7, 17))
      expect(resp.daily_exercise).to eq(exercise)
    end
  end
end
