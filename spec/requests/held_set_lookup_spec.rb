require "rails_helper"

RSpec.describe "Requests from a page left open on a paused user's held set", type: :request do
  include ActiveJob::TestHelper

  let(:user) { create_user_with_key(email: "held@example.com").tap { |owner| owner.update!(learner_notes_enabled: true) } }
  let(:wednesday) { Time.utc(2026, 11, 18, 15) }
  let(:yesterday) { Date.new(2026, 11, 17) }
  let(:problem_set) do
    { "code_review" => { "question" => "Find the bug", "snippet" => "def a; end", "concept" => "n_plus_one" },
      "pattern" => { "title" => "Service Objects", "question" => "When?", "concept" => "service_objects" },
      "challenge" => FakeService::EXERCISE_PROBLEM_SET["challenge"],
      "pseudocode_to_code" => FakeService::EXERCISE_PROBLEM_SET["pseudocode_to_code"] }
  end
  let!(:held) { set_on(yesterday) }
  let!(:shown_scope) { held.draft_scope }
  let(:not_current) { "This set is no longer current. Reload the page to get today's set." }
  let(:carried_forward) do
    "This page is from yesterday, so changes can't be saved or submitted until you reload. " \
      "Reloading brings this same set forward to today, with the answers saved so far."
  end

  around { |example| travel_to(wednesday) { example.run } }

  before do
    stub_env("LEARNER_NOTES" => "1")
    user.update!(paused_generation_at: yesterday.in_time_zone("UTC") + 9.hours)
    allow_any_instance_of(AiService).to receive(:duck_response).and_return("What runs first?")
    allow_any_instance_of(AiService).to receive(:critique_pseudocode).and_return(gaps_found: false, gaps: [])
    login_as(user)
  end

  def set_on(date)
    DailyExercise.create!(user: user, date: date, generated_at: Time.current, language: "ruby_rails", problem_set: problem_set)
  end

  def lookup(on) = stub_env("HELD_SET_LOOKUP" => on ? "1" : nil)

  def body = response.parsed_body

  HELD_SET_CALLERS = {
    "an autosave" => ->(scope) { post responses_path, params: { response: { draft_scope: scope, answers: { code_review: "Per row." } } }, as: :json },
    "a duck send" => ->(scope) { post duck_thread_responses_path, params: { section: "code_review", message: "hi", version: 0, draft_scope: scope }, as: :json },
    "a duck Clear" => ->(scope) { delete duck_thread_responses_path, params: { section: "code_review", draft_scope: scope }, as: :json },
    "the pseudocode critique" => ->(scope) { post pseudocode_critique_responses_path, params: { section: "pseudocode_to_code", pseudocode: "sort then walk", draft_scope: scope }, as: :json },
    "a learner note save" => ->(scope) { patch learner_note_path, params: { learner_note: "Lost on the loop.", draft_scope: scope }, as: :json }
  }.freeze

  HELD_SET_CALLERS.each do |name, send_request|
    describe name do
      it "works on the held set and leaves it dated today with HELD_SET_LOOKUP on" do
        lookup(true)

        instance_exec(shown_scope, &send_request)

        expect(response).to have_http_status(:ok)
        expect(held.reload.date).to eq(Date.current)
        expect(user.daily_exercises.for_date.sole).to eq(held)
      end

      it "refuses with the not-current message and moves nothing with HELD_SET_LOOKUP off" do
        lookup(false)

        instance_exec(shown_scope, &send_request)

        expect(response).to have_http_status(:not_found)
        expect(body).to eq("status" => "error", "error" => not_current)
        expect(held.reload.date).to eq(yesterday)
      end

      it "adds the outcome and the banner sentence only with STALE_SET_BANNER on" do
        lookup(false)
        stub_env("STALE_SET_BANNER" => "1")

        instance_exec(shown_scope, &send_request)

        expect(response).to have_http_status(:not_found)
        expect(body).to eq("status" => "not_current", "error" => not_current, "banner" => carried_forward)
      end
    end
  end

  describe "the explanation box" do
    let(:shown) { { note_id: "1", explanation_stamp: "x", draft_scope: shown_scope } }

    it "moves the held set before deciding, so an unsubmitted set gets the before-submit refusal" do
      lookup(true)

      post learner_explanation_path, params: { section: "code_review", explanation: "One per row.", draft_scope: shown_scope }, as: :json

      expect(response).to have_http_status(:unprocessable_content)
      expect(body["error"]).to eq(I18n.t("learner_notes.explain.before_submit"))
      expect(held.reload.date).to eq(Date.current)
    end

    it "answers every action with the not-current message when no set is current" do
      lookup(false)
      stub_env("STALE_SET_BANNER" => "1")

      post learner_explanation_path, params: { section: "code_review", explanation: "One per row.", draft_scope: shown_scope }, as: :json
      expect([ response.status, body ]).to eq([ 404, { "status" => "not_current", "error" => not_current, "banner" => carried_forward } ])

      post reply_learner_explanation_path, params: shown, as: :json
      expect([ response.status, body ]).to eq([ 404, { "status" => "not_current", "error" => not_current, "banner" => carried_forward } ])

      get reply_status_learner_explanation_path, params: shown, as: :json
      expect([ response.status, body ]).to eq([ 404, { "status" => "not_current", "error" => not_current, "banner" => carried_forward } ])
    end
  end

  describe "a pseudocode critique from an older set after a newer one was generated while paused" do
    let!(:older) { set_on(yesterday - 1) }

    before do
      lookup(true)
      user.update!(paused_generation_at: older.date.in_time_zone("UTC") + 9.hours)
    end

    def critique_from(scope)
      post pseudocode_critique_responses_path,
           params: { section: "pseudocode_to_code", pseudocode: "the older page's plan", draft_scope: scope }, as: :json
    end

    it "refuses as stale, creating no response, claiming nothing and calling no provider" do
      stub_env("STALE_SET_BANNER" => "1")
      expect_any_instance_of(AiService).not_to receive(:critique_pseudocode)

      critique_from(older.draft_scope)

      expect(response).to have_http_status(:conflict)
      expect(body).to include("status" => "stale", "banner" => I18n.t(StaleSetNotice.newer_set(:stale)))
      expect(DailyResponse.where(daily_exercise: [ held, older ])).to be_empty
    end

    it "refuses a request that posts no scope the same way" do
      expect_any_instance_of(AiService).not_to receive(:critique_pseudocode)

      critique_from(nil)

      expect(response).to have_http_status(:conflict)
      expect(body["status"]).to eq("stale")
      expect(DailyResponse.where(daily_exercise: [ held, older ])).to be_empty
    end

    it "leaves the newer set's critique unclaimed when its response already exists" do
      draft = user.daily_responses.create!(daily_exercise: held, date: yesterday, answers: { "code_review" => "Draft." })

      critique_from(older.draft_scope)

      expect(response).to have_http_status(:conflict)
      expect(draft.reload.pseudocode_rounds).to eq({})
    end
  end

  describe "Start over" do
    let!(:draft) { user.daily_responses.create!(daily_exercise: held, date: yesterday, answers: { "code_review" => "Draft." }) }

    it "clears the held set's answers with HELD_SET_LOOKUP on, in place of the not-today refusal" do
      lookup(true)

      delete start_over_response_path(draft)

      expect(response).to redirect_to(root_path)
      expect(flash[:notice]).to eq(I18n.t("flash.responses.answers_cleared"))
      expect(DailyResponse.exists?(draft.id)).to be(false)
      expect(held.reload.date).to eq(Date.current)
    end

    it "keeps the not-today refusal with HELD_SET_LOOKUP off" do
      lookup(false)

      delete start_over_response_path(draft)

      expect(flash[:alert]).to eq(I18n.t("flash.responses.start_over_not_today"))
      expect(draft.reload.date).to eq(yesterday)
    end

    it "still refuses on an older stray set the pause does not hold" do
      lookup(true)
      stray = set_on(yesterday - 2)
      stray_draft = user.daily_responses.create!(daily_exercise: stray, date: stray.date, answers: { "code_review" => "Old." })

      delete start_over_response_path(stray_draft)

      expect(flash[:alert]).to eq(I18n.t("flash.responses.start_over_not_today"))
      expect(stray_draft.reload.date).to eq(yesterday - 2)
    end

    it "leaves the held set where it is when Start over names a response on another set" do
      lookup(true)
      stray = set_on(yesterday - 2)
      stray_draft = user.daily_responses.create!(daily_exercise: stray, date: stray.date, answers: { "code_review" => "Old." })

      delete start_over_response_path(stray_draft)

      expect(flash[:alert]).to eq(I18n.t("flash.responses.start_over_not_today"))
      expect(held.reload.date).to eq(yesterday)
      expect(draft.reload.date).to eq(yesterday)
    end
  end

  describe "Generate a new set" do
    it "regenerates the moved set with HELD_SET_LOOKUP on, in place of nothing to regenerate" do
      lookup(true)
      held.update_columns(regenerated_at: 1.day.ago)

      expect { post regenerate_path, params: { draft_scope: shown_scope } }.to have_enqueued_job(RegenerateExerciseJob)

      expect(response).to redirect_to(root_path)
      expect(held.reload).to have_attributes(date: Date.current, regenerating_since: be_present)
    end

    it "neither moves nor regenerates the held set when the page's scope doesn't match, keeping its draft" do
      lookup(true)
      draft = user.daily_responses.create!(daily_exercise: held, date: yesterday, answers: { "code_review" => "Draft." })

      expect { post regenerate_path, params: { draft_scope: "#{held.id}-1" } }.not_to have_enqueued_job(RegenerateExerciseJob)

      expect(response).to redirect_to(root_path)
      expect(flash[:alert]).to eq(I18n.t("flash.daily_exercises.regenerate_stale"))
      expect(held.reload).to have_attributes(date: yesterday, regenerating_since: nil)
      expect(draft.reload.answers).to eq("code_review" => "Draft.")
    end

    it "redirects with the not-current flash and claims nothing with HELD_SET_LOOKUP off" do
      lookup(false)

      expect { post regenerate_path, params: { draft_scope: shown_scope } }.not_to have_enqueued_job(RegenerateExerciseJob)

      expect(flash[:alert]).to eq("This set is no longer current, so it wasn't replaced.")
      expect(held.reload).to have_attributes(date: yesterday, regenerating_since: nil)
    end
  end

  it "never moves a submitted held set, and the request refuses" do
    lookup(true)
    user.daily_responses.create!(daily_exercise: held, date: yesterday, answers: { "code_review" => "Done." }, submitted_at: 1.day.ago)

    instance_exec(shown_scope, &HELD_SET_CALLERS.fetch("an autosave"))

    expect(response).to have_http_status(:not_found)
    expect(body["error"]).to eq(not_current)
    expect(held.reload.date).to eq(yesterday)
  end

  it "uses today's set and moves nothing when today already has one" do
    lookup(true)
    today = set_on(Date.current)

    instance_exec(today.draft_scope, &HELD_SET_CALLERS.fetch("an autosave"))

    expect(response).to have_http_status(:ok)
    expect(today.reload.daily_response.answers).to eq("code_review" => "Per row.")
    expect(held.reload.date).to eq(yesterday)
  end

  describe "an autosave with no set at all" do
    before { held.destroy! }

    [ nil, "1" ].each do |switch|
      it "answers the message, not a bare 404, with HELD_SET_LOOKUP #{switch ? "on" : "off"}" do
        stub_env("HELD_SET_LOOKUP" => switch)

        instance_exec(shown_scope, &HELD_SET_CALLERS.fetch("an autosave"))

        expect(response).to have_http_status(:not_found)
        expect(body).to eq("status" => "error", "error" => not_current)
      end
    end

    it "redirects an HTML save to the dashboard with the message" do
      post responses_path, params: { response: { answers: { code_review: "Per row." } } }

      expect(response).to redirect_to(root_path)
      expect(flash[:alert]).to eq(not_current)
    end
  end

  describe "paused, with HELD_SET_LOOKUP off and STALE_SET_BANNER on" do
    before do
      lookup(false)
      stub_env("STALE_SET_BANNER" => "1")
      user.daily_responses.create!(daily_exercise: held, date: yesterday, answers: { "code_review" => "Saved before midnight." })
    end

    it "answers freshness out of date with the carry-forward sentence, and a reload brings the same set forward" do
      get dashboard_freshness_path, params: { shown: shown_scope }

      expect(body).to eq("stale" => false, "replaced" => false, "out_of_date" => true, "banner" => carried_forward)
      expect(held.reload.date).to eq(yesterday)

      get root_path

      expect(held.reload.date).to eq(Date.current)
      expect(held.draft_scope).to eq(shown_scope)
      expect(held.daily_response.date).to eq(Date.current)
      expect(response.body).to include("Saved before midnight.")
      expect(response.body).to include(%(data-fresh-day-shown-value="#{shown_scope}"))
    end

    it "gives a refused autosave the same sentence" do
      instance_exec(shown_scope, &HELD_SET_CALLERS.fetch("an autosave"))

      expect(body).to include("status" => "not_current", "banner" => carried_forward)
    end
  end
end
