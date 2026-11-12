require "rails_helper"

RSpec.describe "Dashboard recording that a set was opened", type: :request do
  include ActiveJob::TestHelper

  let(:user) { create_user_with_key }
  let(:monday_noon) { Time.utc(2026, 7, 13, 12) }
  let(:problem_set) { { "code_review" => { "question" => "Find the bug", "snippet" => "def a; end" } } }

  def set_for(date, **columns)
    DailyExercise.create!(user: user, date: date, generated_at: monday_noon - 4.hours, problem_set: problem_set, **columns)
  end

  it "stamps today's set the first time its owner's dashboard shows it, and never again" do
    exercise = travel_to(monday_noon) { set_for(Date.current) }
    written = exercise.updated_at

    travel_to(monday_noon) do
      login_as(user)
      get root_path
    end
    travel_to(monday_noon + 3.hours) { get root_path }

    expect(response.body).to include('data-rating-for="code_review"')
    expect(exercise.reload).to have_attributes(opened_at: monday_noon, updated_at: written)
  end

  it "leaves a set unstamped while it is being regenerated, since the page shows the spinner" do
    travel_to(monday_noon) do
      exercise = set_for(Date.current, regenerating_since: Time.current)
      login_as(user)

      get root_path

      expect(response.body).to include("Generating your personalized exercise set")
      expect(exercise.reload.opened_at).to be_nil
    end
  end

  it "stamps nothing on a page that is generating today's set" do
    travel_to(monday_noon) do
      earlier = set_for(Date.current - 3)
      login_as(user)

      expect { get root_path }.to have_enqueued_job(GenerateDailyExercisesJob)

      expect(response.body).to include("Generating your personalized exercise set")
      expect(earlier.reload.opened_at).to be_nil
    end
  end

  it "stamps the held set a paused user is shown" do
    travel_to(monday_noon) do
      held = set_for(Date.current - 3)
      user.update!(paused_generation_at: (Date.current - 3).in_time_zone("UTC") + 9.hours)
      login_as(user)

      get root_path

      expect(response.body).to include('data-rating-for="code_review"')
      expect(held.reload).to have_attributes(date: Date.current, opened_at: monday_noon)
    end
  end

  it "stamps nothing for another account's set" do
    travel_to(monday_noon) do
      other = User.create!(email: "other@example.com")
      theirs = DailyExercise.create!(user: other, date: Date.current, generated_at: Time.current, problem_set: problem_set)
      set_for(Date.current)
      login_as(user)

      get root_path

      expect(theirs.reload.opened_at).to be_nil
    end
  end

  it "does not stamp from the status poll" do
    travel_to(monday_noon) do
      exercise = set_for(Date.current)
      login_as(user)

      get dashboard_status_path

      expect(exercise.reload.opened_at).to be_nil
    end
  end
end
