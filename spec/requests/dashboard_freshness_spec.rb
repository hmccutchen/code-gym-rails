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

    it "is fresh when the page already shows today's set" do
      today = set_for(Date.current)

      expect(freshness(shown: today.draft_scope)).to eq("stale" => false, "replaced" => false)
    end

    it "is stale when today's set is not the set the page shows" do
      yesterday = set_for(Date.current - 1)
      set_for(Date.current)

      expect(freshness(shown: yesterday.draft_scope)).to eq("stale" => true, "replaced" => false)
    end

    it "is stale and replaced when today's set was written again after the page loaded" do
      today = set_for(Date.current)
      shown = today.draft_scope
      today.update!(generated_at: Time.current + 1.second)

      expect(freshness(shown: shown)).to eq("stale" => true, "replaced" => true)
    end

    it "is stale when the page showed no set and today's set now exists" do
      set_for(Date.current)

      expect(freshness(shown: "")).to eq("stale" => true, "replaced" => false)
      expect(freshness).to eq("stale" => true, "replaced" => false)
    end

    it "is fresh when today has no set, whatever the page shows" do
      yesterday = set_for(Date.current - 1)

      expect(freshness(shown: yesterday.draft_scope)).to eq("stale" => false, "replaced" => false)
      expect(freshness).to eq("stale" => false, "replaced" => false)
    end

    it "takes the set's answer for the shown scope, which is where a regenerating set is held back" do
      today = set_for(Date.current, regenerating_since: Time.current)
      asked = []
      allow_any_instance_of(DailyExercise).to receive(:freshness_against).and_wrap_original do |original, scope|
        asked << scope
        original.call(scope)
      end

      expect(freshness(shown: "#{today.id}-1")).to eq("stale" => false, "replaced" => false)
      expect(asked).to eq([ "#{today.id}-1" ])
    end

    it "raises on an answer from the set that it has no reply for" do
      set_for(Date.current)
      allow_any_instance_of(DailyExercise).to receive(:freshness_against).and_return(:unheard_of)

      expect { get dashboard_freshness_path }.to raise_error(KeyError)
    end

    it "is stale but not replaced for a shown value that is not a string" do
      today = set_for(Date.current)

      get dashboard_freshness_path, params: { shown: [ "#{today.id}-1" ] }
      expect(response.parsed_body).to eq("stale" => true, "replaced" => false)

      get dashboard_freshness_path, params: { shown: { id: today.id } }
      expect(response.parsed_body).to eq("stale" => true, "replaced" => false)
    end

    it "answers the same for another account's scope as for any other set" do
      other = User.create!(email: "other@example.com")
      theirs = set_for(Date.current, owner: other)
      theirs_rewritten = theirs.draft_scope.sub(/\d+\z/, "1")
      set_for(Date.current)

      expect(freshness(shown: theirs.draft_scope)).to eq("stale" => true, "replaced" => false)
      expect(freshness(shown: theirs_rewritten)).to eq("stale" => true, "replaced" => false)
    end

    it "is not replaced by another account's rewritten set when this account has none" do
      other = User.create!(email: "other@example.com")
      theirs = set_for(Date.current, owner: other)

      expect(freshness(shown: "#{theirs.id}-1")).to eq("stale" => false, "replaced" => false)
    end

    it "never counts another account's set" do
      other = User.create!(email: "other@example.com")
      set_for(Date.current, owner: other)

      expect(freshness).to eq("stale" => false, "replaced" => false)
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

      expect(freshness).to eq("stale" => false, "replaced" => false)
      expect(held.reload.date).to eq(Date.current - 3)
    end
  end

  describe "a held set and the out-of-date answer" do
    let(:generation_sentence) do
      "This set is from yesterday, so changes to it can't be saved or submitted. " \
        "Reloading starts today's set, and yesterday's unsubmitted answers won't be shown again."
    end

    before { login_as(user) }

    def pause_on(date) = user.update!(paused_generation_at: date.in_time_zone("UTC") + 9.hours)

    it "answers current for a held set whose scope matches the page, and leaves it on its own date, with HELD_SET_LOOKUP on" do
      stub_env("HELD_SET_LOOKUP" => "1", "STALE_SET_BANNER" => "1")
      held = set_for(Date.current - 1)
      pause_on(Date.current - 1)

      expect(freshness(shown: held.draft_scope)).to eq("stale" => false, "replaced" => false)
      expect(held.reload.date).to eq(Date.current - 1)
    end

    it "answers current with no set and a shown scope under HELD_SET_LOOKUP alone" do
      stub_env("HELD_SET_LOOKUP" => "1")
      yesterday = set_for(Date.current - 1)

      expect(freshness(shown: yesterday.draft_scope)).to eq("stale" => false, "replaced" => false)
    end

    it "answers out of date, with the sentence for what Reload does, when the page shows a set and today has none" do
      stub_env("STALE_SET_BANNER" => "1")
      yesterday = set_for(Date.current - 1)

      expect(freshness(shown: yesterday.draft_scope))
        .to eq("stale" => false, "replaced" => false, "out_of_date" => true, "banner" => generation_sentence)
    end

    it "answers out of date with HELD_SET_LOOKUP on too when no held set exists" do
      stub_env("HELD_SET_LOOKUP" => "1", "STALE_SET_BANNER" => "1")
      yesterday = set_for(Date.current - 1)

      expect(freshness(shown: yesterday.draft_scope)).to include("out_of_date" => true, "banner" => generation_sentence)
    end

    it "answers current when the page shows no set, even with STALE_SET_BANNER on" do
      stub_env("STALE_SET_BANNER" => "1")

      expect(freshness(shown: "")).to eq("stale" => false, "replaced" => false)
      expect(freshness).to eq("stale" => false, "replaced" => false)
    end

    it "carries the newer-set and replaced sentences on stale replies only with STALE_SET_BANNER on" do
      yesterday = set_for(Date.current - 1)
      today = set_for(Date.current)
      rewritten = today.draft_scope
      stub_env("STALE_SET_BANNER" => "1")

      expect(freshness(shown: yesterday.draft_scope)).to eq(
        "stale" => true, "replaced" => false,
        "banner" => "A newer set is ready, so changes to this one can't be saved. Reloading shows the new set."
      )
      today.update!(generated_at: Time.current + 1.second)
      expect(freshness(shown: rewritten)).to eq(
        "stale" => true, "replaced" => true,
        "banner" => "This set was replaced, so changes to it can't be saved. Reloading shows the current one."
      )
    end

    it "uses the weekend sentence on a Saturday" do
      stub_env("STALE_SET_BANNER" => "1")
      travel_back
      travel_to(Time.utc(2026, 7, 18, 12))
      login_as(user)
      friday = set_for(Date.current - 1)

      expect(freshness(shown: friday.draft_scope)["banner"]).to include("Reloading shows today's page")
    end

    it "uses the submitted sentence when the shown set was submitted" do
      stub_env("STALE_SET_BANNER" => "1")
      yesterday = set_for(Date.current - 1)
      user.daily_responses.create!(daily_exercise: yesterday, date: yesterday.date, answers: {}, submitted_at: 1.day.ago)

      expect(freshness(shown: yesterday.draft_scope)["banner"]).to eq("This page is from yesterday. Reload it to see today's page.")
    end

    it "writes nothing for an out-of-date answer" do
      stub_env("STALE_SET_BANNER" => "1")
      held = set_for(Date.current - 1)
      pause_on(Date.current - 1)
      before = held.reload.attributes

      expect { freshness(shown: held.draft_scope) }.not_to have_enqueued_job
      expect(held.reload.attributes).to eq(before)
      expect(held.opened_at).to be_nil
    end
  end

  it "redirects a signed-out check to the login page" do
    get dashboard_freshness_path, headers: { "Accept" => "application/json" }

    expect(response).to redirect_to(login_path)
    expect(session[:return_to]).to be_nil
  end
end
