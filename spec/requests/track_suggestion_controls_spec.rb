require "rails_helper"

RSpec.describe "Learning track suggestion controls", type: :request do
  let(:json) { { "Content-Type" => "application/json", "Accept" => "application/json" } }
  def page_html = Nokogiri::HTML(response.body)

  def track_user(**attributes)
    create_user_with_key.tap do |user|
      user.update!(learning_track: "junior", section_kind_levels: LearningTrack.preset_levels, **attributes)
    end
  end

  def reviewed_day(user, date)
    exercise = DailyExercise.create!(user: user, date: date, generated_at: Time.current,
      problem_set: { "code_review" => { "question" => "q", "snippet" => "s", "pitched_at" => "junior" } })
    DailyResponse.create!(user: user, daily_exercise: exercise, date: date, submitted_at: Time.current,
      answers: { "code_review" => "a" * 20 }, section_ratings: { "code_review" => "right_level" },
      ai_review: { "code_review" => { "rating" => "solid", "correct" => "c" } })
  end

  def with_own_proposal(user)
    [ 2, 1, 0 ].each { |ago| reviewed_day(user, Date.current - ago) }
    login_as(user)
  end

  def proposal = page_html.at_css("#track-proposal")

  around { |example| travel_to(Time.utc(2026, 10, 14, 15)) { example.run } }

  describe "the dashboard proposal" do
    it "applies in place and links to the off switch while the user has answered fewer than the threshold" do
      user = track_user(track_proposals_answered: LearningTrack::IN_PLACE_ANSWERS - 1)
      with_own_proposal(user)

      get root_path

      expect(proposal.at_css("[data-apply]")).to be_present
      expect(proposal.at_css("[data-change-in-setup]")).to be_nil
      expect(proposal["data-answer-url"]).to eq(learning_track_answer_path)
      expect(proposal.text).to include("turn these suggestions off in Setup")
      expect(proposal.at_css(%(a[href="#{setup_path(anchor: "learning-track")}"]))).to be_present
    end

    it "sends the user to the Exercise mix with the suggested kinds once they have answered the threshold" do
      user = track_user(track_proposals_answered: LearningTrack::IN_PLACE_ANSWERS)
      with_own_proposal(user)

      get root_path

      expect(proposal.at_css("[data-apply]")).to be_nil
      expect(proposal.at_css("[data-not-now]")).to be_present
      link = proposal.at_css("[data-change-in-setup]")
      expect(link.text).to eq("Change it in Setup")
      expect(link["href"]).to eq(setup_path(suggested: [ "code_review" ], suggested_level: "senior", anchor: "exercise-mix"))
    end

    it "offers no keep-at-junior buttons on a bundle that goes to Setup" do
      user = track_user(track_proposals_answered: LearningTrack::IN_PLACE_ANSWERS,
                        section_kind_levels: LearningTrack.preset_levels.merge("code_review" => "senior"))
      reviewed_day(user, Date.current)
      login_as(user)

      get root_path

      expect(proposal.css("[data-step]")).not_to be_empty
      expect(proposal.css("[data-remove-step]")).to be_empty
    end

    # An excluded kind's difficulty is disabled on Setup, so sending the user there would leave nothing to change.
    it "keeps applying in place when a proposed kind is excluded" do
      user = track_user(track_proposals_answered: LearningTrack::IN_PLACE_ANSWERS,
                        section_kind_levels: LearningTrack.preset_levels.merge("code_review" => "senior"),
                        excluded_section_kinds: [ "security_review" ])
      reviewed_day(user, Date.current)
      login_as(user)

      get root_path

      expect(proposal.css("[data-kind]").map { |step| step["data-kind"] }).to include("security_review")
      expect(proposal.at_css("[data-apply]")).to be_present
      expect(proposal.at_css("[data-change-in-setup]")).to be_nil
    end

    it "shows nothing while suggestions are off, and the same proposal once they are back on" do
      user = track_user(track_suggestions: false)
      with_own_proposal(user)

      get root_path
      expect(proposal).to be_nil

      user.update!(track_suggestions: true)
      get root_path
      expect(proposal.text).to include("Move Code Review up to senior?")
    end
  end

  describe "POST /learning_track/answer" do
    it "counts one answer per request" do
      user = track_user
      login_as(user)

      2.times { post learning_track_answer_path, params: {}.to_json, headers: json }

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)).to eq("answered" => 2)
      expect(user.reload.track_proposals_answered).to eq(2)
    end

    it "is not found for an account off the track" do
      user = create_user_with_key
      login_as(user)

      post learning_track_answer_path, params: {}.to_json, headers: json

      expect(response).to have_http_status(:not_found)
      expect(user.reload.track_proposals_answered).to eq(0)
    end
  end

  describe "PATCH /profile track_suggestions" do
    it "turns suggestions off and back on" do
      user = track_user
      login_as(user)

      patch profile_path, params: { user: { track_suggestions: false } }.to_json, headers: json
      expect(response).to have_http_status(:ok)
      expect(user.reload.track_suggestions).to be(false)

      patch profile_path, params: { user: { track_suggestions: true } }.to_json, headers: json
      expect(user.reload.track_suggestions).to be(true)
    end

    [ "false", nil, 0 ].each do |value|
      it "refuses #{value.inspect} rather than casting it" do
        user = track_user
        login_as(user)

        patch profile_path, params: { user: { track_suggestions: value } }.to_json, headers: json

        expect(response).to have_http_status(:unprocessable_content)
        expect(user.reload.track_suggestions).to be(true)
      end
    end
  end

  describe "Setup" do
    it "shows the suggestions switch with its current state and warns that leaving is final" do
      user = track_user(track_suggestions: false)
      login_as(user)

      get setup_path

      box = page_html.at_css("#track-suggestions")
      expect(box).to be_present
      expect(box["checked"]).to be_nil
      expect(page_html.at_css("#learning-track").text).to include("You can't rejoin the track afterwards.")
    end

    it "opens the Exercise mix and marks the suggested kinds" do
      user = track_user
      login_as(user)

      get setup_path(suggested: %w[code_review pattern], suggested_level: "junior")

      expect(page_html.at_css("#exercise-mix")["open"]).not_to be_nil
      expect(page_html.at_css("#mix-suggested-note").text).to eq("Code Gym suggested moving Code Review and Pattern of the Month to Junior. Change their difficulty below.")
      marked = page_html.css(".mix-difficulty.mix-suggested")
      expect(marked.map { |field| field["data-kind"] }).to match_array(%w[code_review pattern])
      expect(marked.map { |field| field["aria-describedby"] }.uniq).to eq([ "mix-suggested-note" ])
    end

    it "ignores kinds that are not registered" do
      user = track_user
      login_as(user)

      get setup_path(suggested: [ "nope", { "a" => 1 } ], suggested_level: "senior")

      expect(page_html.at_css("#exercise-mix")["open"]).to be_nil
      expect(page_html.css(".mix-suggested")).to be_empty
    end

    [ nil, "principal_engineer", "x" ].each do |level|
      it "marks nothing when the suggested level is #{level.inspect}" do
        login_as(track_user)

        get setup_path(suggested: [ "code_review" ], suggested_level: level)

        expect(page_html.at_css("#exercise-mix")["open"]).to be_nil
        expect(page_html.css(".mix-suggested")).to be_empty
      end
    end

    it "marks nothing for an account off the track" do
      login_as(create_user_with_key)

      get setup_path(suggested: [ "code_review" ], suggested_level: "senior")

      expect(page_html.at_css("#exercise-mix")["open"]).to be_nil
      expect(page_html.css(".mix-suggested")).to be_empty
    end
  end
end
