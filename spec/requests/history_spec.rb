require "rails_helper"

RSpec.describe "History", type: :request do
  let(:user) { create_user_with_key }

  def create_session_for(owner, date:, submitted: true, reviewed: false, rating: nil, concept_tags: {}, section_ratings: nil, legacy_rating: nil)
    exercise = DailyExercise.create!(
      user: owner, date: date,
      problem_set: {
        "code_review" => { "question" => "q-#{date}", "snippet" => "s" },
        "pattern" => { "title" => "Pat-#{date}", "question" => "pattern-q-#{date}" },
        "challenge" => { "question" => "challenge-q-#{date}" }
      },
      generated_at: Time.current
    )
    # If a rating is provided and section_ratings is not explicitly set, use the rating for all sections
    final_section_ratings = if section_ratings.present?
      section_ratings
    elsif rating.present? || legacy_rating.present?
      val = rating || legacy_rating
      { "code_review" => val, "pattern" => val, "challenge" => val }
    else
      {}
    end
    DailyResponse.create!(
      user: owner, daily_exercise: exercise, date: date,
      answers: { "code_review" => "Answer with plenty of substance" },
      submitted_at: submitted ? Time.current : nil,
      section_ratings: final_section_ratings,
      concept_tags: concept_tags,
      ai_review: reviewed ? { "code_review" => { "rating" => "solid", "correct" => "Spotted the issue on #{date}" } } : nil
    )
  end

  describe "GET /history" do
    it "requires login" do
      get history_path
      expect(response).to redirect_to(login_path)
    end

    it "lists only the current user's submitted responses, newest first" do
      other = create_user_with_key(email: "other@example.com", name: "Other")
      old   = create_session_for(user, date: 3.days.ago.to_date, reviewed: true, section_ratings: {}, legacy_rating: "too_hard")
      newer = create_session_for(user, date: 1.day.ago.to_date)
      create_session_for(user, date: Date.current, submitted: false)   # draft — excluded
      create_session_for(other, date: 2.days.ago.to_date)              # other user — excluded

      login_as(user)
      get history_path

      expect(response.body).to include(newer.date.strftime("%A, %B %-d, %Y"))
      expect(response.body).to include(old.date.strftime("%A, %B %-d, %Y"))
      expect(response.body).not_to include(Date.current.strftime("%A, %B %-d, %Y"))
      expect(response.body).not_to include(2.days.ago.to_date.strftime("%A, %B %-d, %Y"))
      expect(response.body.index(newer.date.strftime("%A, %B %-d, %Y")))
        .to be < response.body.index(old.date.strftime("%A, %B %-d, %Y"))
    end

    it "shows rating, concept tags, review content for reviewed entries, and a fallback otherwise" do
      create_session_for(user, date: 3.days.ago.to_date, reviewed: true, section_ratings: {}, legacy_rating: "too_hard",
                         concept_tags: { "code_review" => "n_plus_one" })
      create_session_for(user, date: 1.day.ago.to_date)

      login_as(user)
      get history_path

      expect(response.body).to include("Too hard")
      expect(response.body).to include("N plus one")
      expect(response.body).to include("What you got right")
      expect(response.body).to include("Spotted the issue on #{3.days.ago.to_date}")
      expect(response.body).to include("No AI review requested.")
      expect(response.body).to include("1/3 sections")
    end

    it "renders each entry's problems and the user's answers" do
      session = create_session_for(user, date: 1.day.ago.to_date)

      login_as(user)
      get history_path

      expect(response.body).to include("q-#{session.date}")
      expect(response.body).to include("Answer with plenty of substance")
      expect(response.body).to include("Problems &amp; answers")
    end

    it "anchors each entry by response id" do
      session = create_session_for(user, date: 1.day.ago.to_date)

      login_as(user)
      get history_path

      expect(response.body).to include(%(id="response-#{session.id}"))
    end

    it "opens the newest entry's problems and leaves older ones closed" do
      create_session_for(user, date: 1.day.ago.to_date)
      create_session_for(user, date: 3.days.ago.to_date)

      login_as(user)
      get history_path

      # Two entries, exactly one open problems block — the first.
      expect(response.body.scan(/<details class="answers" open>/).size).to eq(1)
      expect(response.body.scan(/<details class="answers">/).size).to eq(1)
    end

    it "renders an entry whose stored problem_set is missing sections, without breaking the page" do
      sparse = DailyExercise.create!(
        user: user, date: 5.days.ago.to_date, generated_at: Time.current,
        problem_set: { "code_review" => { "question" => "only-section", "snippet" => "s" } }
      )
      DailyResponse.create!(user: user, daily_exercise: sparse, date: 5.days.ago.to_date,
                            answers: { "code_review" => "Answer with plenty of substance" },
                            submitted_at: Time.current)
      intact = create_session_for(user, date: 1.day.ago.to_date)

      login_as(user)
      get history_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("only-section")
      # The malformed row must not take the rest of the page down with it.
      expect(response.body).to include("q-#{intact.date}")
    end
  end

  describe "review summary label" do
    it "names the user's provider on the history review summary" do
      user.update!(provider: "gemini")
      login_as(user)
      create_session_for(user, date: Date.current, reviewed: true)

      get history_path

      expect(response.body).to include("Gemini&#39;s review")
      expect(response.body).not_to include("Claude&#39;s review")
    end
  end
end
