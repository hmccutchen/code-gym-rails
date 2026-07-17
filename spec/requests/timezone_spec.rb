require "rails_helper"

RSpec.describe "Per-user timezone", type: :request do
  include ActiveSupport::Testing::TimeHelpers
  include ActiveJob::TestHelper

  # 2026-07-15 02:30 UTC == 2026-07-14 19:30 America/Los_Angeles:
  # a UTC Wednesday whose local day is the previous day, Tuesday — a weekday
  # in both zones, so the UTC-day dashboard branch would still try to
  # generate (not silently no-op on a UTC weekend) if the zone fix were
  # missing.
  let(:instant) { Time.utc(2026, 7, 15, 2, 30) }
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
      local_today = Time.use_zone("America/Los_Angeles") { Date.current } # 2026-07-14
      DailyExercise.create!(user: pacific, date: local_today,
                            problem_set: full_problem_set, generated_at: Time.current)
      login_as(pacific)

      # Pre-fix the request would treat "today" as the UTC day (07-15), find no
      # exercise, and enqueue generation; the zone fix finds the local-day
      # exercise and enqueues nothing.
      expect { get root_path }.not_to have_enqueued_job(GenerateDailyExercisesJob)
      expect(response).to have_http_status(:ok)
      expect(DailyExercise.where(user: pacific).count).to eq(1)
    end
  end

  it "saves a submitted response under the local date across UTC midnight (lost-work regression)" do
    travel_to(instant) do
      local_today = Time.use_zone("America/Los_Angeles") { Date.current } # 2026-07-14
      exercise = DailyExercise.create!(user: pacific, date: local_today,
                                       problem_set: { "code_review" => {} }, generated_at: Time.current)
      login_as(pacific)

      post responses_path,
           params: { response: { answers: { code_review: "x" * 20 }, submit: "1" } }.to_json,
           headers: { "Content-Type" => "application/json", "Accept" => "application/json" }

      expect(response).to have_http_status(:ok)
      resp = pacific.daily_responses.sole
      # Under the old UTC behavior this would be 2026-07-15; the fix keeps it local.
      expect(resp.date).to eq(Date.new(2026, 7, 14))
      expect(resp.daily_exercise).to eq(exercise)
    end
  end
end
