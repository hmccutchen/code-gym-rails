require "rails_helper"

RSpec.describe PreviewSeed do
  after { ENV.delete("PREVIEW_SEED_EMAIL") }

  def set_target(email = "reviewer@example.com")
    ENV["PREVIEW_SEED_EMAIL"] = email
  end

  describe "the gate" do
    it "does nothing and returns nil when PREVIEW_SEED_EMAIL is unset" do
      expect { PreviewSeed.run! }.not_to change(User, :count)
      expect(PreviewSeed.run!).to be_nil
    end

    it "does nothing when PREVIEW_SEED_EMAIL is blank" do
      set_target("   ")

      expect { PreviewSeed.run! }.not_to change(User, :count)
      expect(PreviewSeed.run!).to be_nil
    end
  end

  describe "the target user" do
    it "creates the named user when absent, with a dummy key that satisfies the API-key gate" do
      set_target

      user = PreviewSeed.run!

      expect(user.email).to eq("reviewer@example.com")
      expect(user.api_key).to eq(PreviewSeed::DUMMY_API_KEY)
      expect(user.provider).to eq("anthropic")
      expect(user).to be_api_key_present
    end

    it "downcases and strips the configured email" do
      set_target("  Reviewer@Example.COM  ")

      expect(PreviewSeed.run!.email).to eq("reviewer@example.com")
    end

    it "finds the existing user instead of creating a second one" do
      set_target
      first = PreviewSeed.run!

      expect { PreviewSeed.run! }.not_to change(User, :count)
      expect(PreviewSeed.run!.id).to eq(first.id)
    end

    # Safety rule 3. This is the test that protects a real account if
    # PREVIEW_SEED_EMAIL is ever set in production.
    it "never overwrites an existing API key" do
      real = User.create!(email: "reviewer@example.com", name: "Real Person")
      real.update!(api_key: "sk-ant-a-real-key", provider: "anthropic")
      set_target

      PreviewSeed.run!

      expect(real.reload.api_key).to eq("sk-ant-a-real-key")
    end

    it "never overwrites an existing name, skill level, or language" do
      real = User.create!(email: "reviewer@example.com", name: "Real Person",
                          skill_level: "strong", language: "javascript")
      set_target

      PreviewSeed.run!

      real.reload
      expect(real.name).to eq("Real Person")
      expect(real.skill_level).to eq("strong")
      expect(real.language).to eq("javascript")
    end

    it "never overwrites an existing provider" do
      real = User.create!(email: "reviewer@example.com", name: "Real Person")
      real.update!(api_key: "AIzaSyReal", provider: "gemini")
      set_target

      PreviewSeed.run!

      expect(real.reload.provider).to eq("gemini")
    end

    it "does not touch users other than the named one" do
      bystander = User.create!(email: "someone-else@example.com", name: "Bystander",
                               skill_level: "beginner")
      set_target

      expect { PreviewSeed.run! }.not_to change { bystander.reload.attributes }
    end
  end

  describe "the seeded content" do
    # Pin to noon UTC: this suite runs Rails in UTC while the default reviewer
    # falls back to User::DEFAULT_TIME_ZONE ("America/New_York"), so bare
    # Date.current here and Date.current inside seed_days' Time.use_zone can
    # land on different calendar days for a few hours around UTC midnight.
    # Freezing to local noon keeps both sides on the same day regardless of
    # when CI runs. (The Kiritimati test below is unaffected either way: it
    # compares against the same frozen instant on both sides.)
    before do
      set_target
      travel_to Time.current.change(hour: 12)
    end

    it "seeds today as an unrated draft so the submit gate is reviewable" do
      user = PreviewSeed.run!
      response = user.daily_responses.find_by(date: Date.current)

      expect(response).not_to be_submitted
      expect(response.rating).to be_nil
      expect(response.answers["code_review"].length).to be > 10
    end

    it "gives today an architecture third section" do
      user = PreviewSeed.run!
      exercise = user.daily_exercises.find_by(date: Date.current)

      expect(exercise.architecture).to be_present
      expect(exercise.challenge).to be_nil
    end

    it "seeds a reviewed day so the AI-review partial is reachable" do
      user = PreviewSeed.run!
      response = user.daily_responses.find_by(date: Date.current - 1)

      expect(response).to be_submitted
      expect(response).to be_reviewed
      expect(response.rating).to eq("right_level")
      expect(response.daily_exercise.challenge).to be_present
    end

    it "seeds a submitted-but-unreviewed day so the no-review branch is reachable" do
      user = PreviewSeed.run!
      response = user.daily_responses.find_by(date: Date.current - 3)

      expect(response).to be_submitted
      expect(response).not_to be_reviewed
    end

    it "tags concepts so history renders concept pills" do
      user = PreviewSeed.run!
      response = user.daily_responses.find_by(date: Date.current - 1)

      expect(response.concept_tags.values.compact).not_to be_empty
    end

    it "seeds a concept reference so the always-visible dropdown has content" do
      PreviewSeed.run!

      expect(ConceptReference.find_by(concept: "n_plus_one", language: "ruby_rails")).to be_present
    end

    # Safety rule 2, at the row level.
    it "is idempotent — a second run creates nothing new" do
      PreviewSeed.run!

      expect { PreviewSeed.run! }.not_to change(DailyExercise, :count)
      expect { PreviewSeed.run! }.not_to change(DailyResponse, :count)
      expect { PreviewSeed.run! }.not_to change(ConceptReference, :count)
    end

    it "never overwrites an existing exercise or response for a seeded date" do
      user = User.create!(email: "reviewer@example.com", name: "Real Person")
      exercise = DailyExercise.create!(
        user: user, date: Date.current, generated_at: 1.day.ago, language: "javascript",
        problem_set: { "code_review" => { "question" => "PRE-EXISTING", "snippet" => "s" } }
      )
      DailyResponse.create!(user: user, daily_exercise: exercise, date: Date.current,
                            answers: { "code_review" => "my real answer here" },
                            submitted_at: 1.day.ago)

      PreviewSeed.run!

      expect(exercise.reload.problem_set.dig("code_review", "question")).to eq("PRE-EXISTING")
      expect(exercise.language).to eq("javascript")
      expect(user.daily_responses.find_by(date: Date.current).answers["code_review"])
        .to eq("my real answer here")
    end

    it "does not fabricate a response against a real user's pre-existing exercise" do
      user = User.create!(email: "reviewer@example.com", name: "Real Person")
      DailyExercise.create!(
        user: user, date: Date.current, generated_at: 1.day.ago, language: "javascript",
        problem_set: { "code_review" => { "question" => "REAL", "snippet" => "s" } }
      )

      PreviewSeed.run!

      expect(user.daily_responses.find_by(date: Date.current)).to be_nil
    end

    it "seeds dates in the user's own time zone, not UTC" do
      user = User.create!(email: "reviewer@example.com", name: "Reviewer",
                          time_zone: "Pacific/Kiritimati")

      PreviewSeed.run!

      local_today = Time.use_zone(user.effective_time_zone) { Date.current }
      expect(user.daily_exercises.pluck(:date)).to include(local_today)
    end
  end
end
