require "rails_helper"

RSpec.describe "GET /dashboard/freshness", type: :request do
  include ActiveJob::TestHelper

  let(:user) { create_user_with_key }
  let(:monday_noon) { Time.utc(2026, 7, 13, 12) }
  let(:problem_set) { { "code_review" => { "question" => "Find the bug", "snippet" => "def a; end" } } }

  around { |example| travel_to(monday_noon) { example.run } }

  def set_for(date, owner: user, **columns)
    DailyExercise.create!(user: owner, date: date, generated_at: Time.current, problem_set: problem_set, **columns)
  end

  def freshness(shown: nil)
    get dashboard_freshness_path, params: { shown: shown }.compact
    expect(response).to have_http_status(:ok)
    response.parsed_body
  end

  context "when signed in" do
    before { login_as(user) }

    it "is stale when today's set is not the set the page shows" do
      yesterday = set_for(Date.current - 1)
      set_for(Date.current)

      expect(freshness(shown: yesterday.draft_scope)).to eq("stale" => true)
    end

    it "is stale when today's set was written again after the page loaded" do
      today = set_for(Date.current)
      shown = today.draft_scope
      today.update!(generated_at: Time.current + 1.second)

      expect(freshness(shown: shown)).to eq("stale" => true)
    end

    it "is fresh when the page already shows today's set" do
      today = set_for(Date.current)

      expect(freshness(shown: today.draft_scope)).to eq("stale" => false)
    end

    it "is stale when the page showed no set and today's set now exists" do
      set_for(Date.current)

      expect(freshness(shown: "")).to eq("stale" => true)
      expect(freshness).to eq("stale" => true)
    end

    it "is fresh when today has no set, whatever the page shows" do
      yesterday = set_for(Date.current - 1)

      expect(freshness(shown: yesterday.draft_scope)).to eq("stale" => false)
      expect(freshness).to eq("stale" => false)
    end

    it "is fresh while today's set is still being regenerated" do
      yesterday = set_for(Date.current - 1)
      set_for(Date.current, regenerating_since: Time.current)

      expect(freshness(shown: yesterday.draft_scope)).to eq("stale" => false)
    end

    it "never counts another account's set" do
      other = User.create!(email: "other@example.com")
      set_for(Date.current, owner: other)

      expect(freshness).to eq("stale" => false)
    end

    it "stamps no set as opened" do
      today = set_for(Date.current)

      freshness

      expect(today.reload.opened_at).to be_nil
    end

    it "starts no generation on a day with no set" do
      expect { freshness }.not_to have_enqueued_job(GenerateDailyExercisesJob)
    end

    it "leaves a paused user's held set on its own date" do
      held = set_for(Date.current - 3)
      user.update!(paused_generation_at: (Date.current - 3).in_time_zone("UTC") + 9.hours)

      expect(freshness).to eq("stale" => false)
      expect(held.reload.date).to eq(Date.current - 3)
    end
  end

  it "redirects a signed-out check to the login page" do
    get dashboard_freshness_path, headers: { "Accept" => "application/json" }

    expect(response).to redirect_to(login_path)
    expect(session[:return_to]).to be_nil
  end
end
