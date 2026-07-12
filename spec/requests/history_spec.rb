require "rails_helper"

RSpec.describe "History", type: :request do
  let(:user) { create_user_with_key }

  def create_session_for(owner, date:, submitted: true, reviewed: false, rating: nil, concept_tags: {})
    exercise = DailyExercise.create!(
      user: owner, date: date,
      problem_set: { "code_review" => { "question" => "q-#{date}", "snippet" => "s" } },
      generated_at: Time.current
    )
    DailyResponse.create!(
      user: owner, daily_exercise: exercise, date: date,
      answers: { "code_review" => "Answer with plenty of substance" },
      submitted_at: submitted ? Time.current : nil,
      rating: rating,
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
      old   = create_session_for(user, date: 3.days.ago.to_date, reviewed: true, rating: :too_hard)
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
      create_session_for(user, date: 3.days.ago.to_date, reviewed: true, rating: :too_hard,
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
  end
end
