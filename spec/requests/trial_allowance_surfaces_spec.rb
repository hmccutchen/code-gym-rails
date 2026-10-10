require "rails_helper"

# Each surface names the reset in the person's zone, never the gate's internal message.
RSpec.describe "A trial at its daily cap", type: :request do
  let(:user) { create_trial_user(provider: "fake", cap: 2, time_zone: "America/New_York") }
  let(:internal) { "Trial account cap reached" }
  let(:cap_sentence) { /Your trial has used its \S+ calls for today, so %s\. .*The count resets at 12:00 am your time, Thursday\./ }

  # Wednesday 2026-10-07, 10am in New York.
  around { |example| travel_to(Time.utc(2026, 10, 7, 14)) { example.run } }

  before do
    2.times do
      ApiUsage.create!(user: user, purpose: "duck_thread", provider: "fake", house_key: true,
                       tokens_in: 1, tokens_out: 1, date: Date.current, created_at: Time.current)
    end
    login_as(user)
  end

  def todays_exercise
    DailyExercise.create!(user: user, date: Date.current, language: "ruby_rails", generated_at: Time.current,
                          problem_set: { "code_review" => { "question" => "q", "snippet" => "s", "concept" => "n_plus_one" } })
  end

  def sentence_for(outcome) = Regexp.new(format(cap_sentence.source, Regexp.escape(outcome)))

  it "answers the thinking partner with the cap sentence" do
    todays_exercise

    post duck_thread_responses_path, params: { section: "code_review", message: "Why?", thread: [] }, as: :json

    expect(response).to have_http_status(:service_unavailable)
    expect(response.parsed_body).to include("status" => "error", "failure" => "trial_allowance_used")
    expect(response.parsed_body["error"]).to match(sentence_for("the thinking partner didn't answer"))
    expect(response.body).not_to include(internal)
  end

  it "keeps the answers and says why the review didn't run" do
    daily_response = DailyResponse.create!(user: user, daily_exercise: todays_exercise, date: Date.current,
                                           answers: { "code_review" => "a" * 20 },
                                           section_ratings: { "code_review" => "right_level" }, submitted_at: Time.current)

    post review_response_path(daily_response)
    follow_redirect!

    expect(response.body).to match(sentence_for("the review didn&#39;t run"))
    expect(response.body).to include("Your answers are saved.")
    expect(response.body).not_to include(internal)
    expect(daily_response.reload.answers["code_review"]).to eq("a" * 20)
  end

  it "says on the dashboard and the status endpoint why no set was generated" do
    GenerateDailyExercisesJob.perform_now(user_id: user.id)

    get dashboard_status_path
    expect(response.parsed_body["status"]).to eq("failed")
    expect(response.parsed_body["message"]).to match(sentence_for("nothing was generated"))
    expect(response.body).not_to include(internal)

    get root_path
    expect(response.body).to match(sentence_for("nothing was generated"))
    expect(response.body).not_to include(internal)
  end
end
