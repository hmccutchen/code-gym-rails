require "rails_helper"

RSpec.describe User, type: :model do
  def create_user(email: "dev@example.com", name: "Dev")
    User.create!(email: email, name: name)
  end

  describe "validations" do
    it "requires a valid email" do
      user = User.new(email: "not-an-email", name: "Dev")
      expect(user).not_to be_valid
      expect(user.errors[:email]).to be_present
    end

    it "rejects duplicate emails case-insensitively" do
      create_user(email: "dev@example.com")
      dupe = User.new(email: "DEV@example.com", name: "Other")
      expect(dupe).not_to be_valid
    end

    it "downcases email before saving" do
      user = User.create!(email: "MiXeD@Example.COM", name: "Dev")
      expect(user.reload.email).to eq("mixed@example.com")
    end

    it "allows a nil provider" do
      user = User.new(email: "dev@example.com", name: "Dev", provider: nil)
      expect(user).to be_valid
    end

    it "accepts anthropic or gemini as the provider" do
      expect(User.new(email: "a@example.com", name: "A", provider: "anthropic")).to be_valid
      expect(User.new(email: "b@example.com", name: "B", provider: "gemini")).to be_valid
    end

    it "rejects an unrecognized provider" do
      user = User.new(email: "c@example.com", name: "C", provider: "openai")
      expect(user).not_to be_valid
      expect(user.errors[:provider]).to be_present
    end

    it "defaults language to ruby_rails" do
      user = create_user
      expect(user.language).to eq("ruby_rails")
    end

    it "accepts ruby_rails, javascript, or mixed as the language" do
      expect(User.new(email: "d@example.com", name: "D", language: "ruby_rails")).to be_valid
      expect(User.new(email: "e@example.com", name: "E", language: "javascript")).to be_valid
      expect(User.new(email: "f@example.com", name: "F", language: "mixed")).to be_valid
    end

    it "rejects an unrecognized language" do
      user = User.new(email: "g@example.com", name: "G", language: "python")
      expect(user).not_to be_valid
      expect(user.errors[:language]).to be_present
    end
  end

  describe "api key encryption" do
    it "persists the api key across reloads" do
      user = create_user
      user.update!(api_key: "sk-ant-secret123")

      expect(user.reload.api_key).to eq("sk-ant-secret123")
      expect(user.api_key_present?).to be true
    end

    it "stores the key encrypted, not in plaintext" do
      user = create_user
      user.update!(api_key: "sk-ant-secret123")

      raw = ActiveRecord::Base.connection.select_value(
        "SELECT api_key FROM users WHERE id = #{user.id}"
      )
      expect(raw).to be_present
      expect(raw).not_to include("sk-ant-secret123")
    end

    it "reports api_key_present? false when no key is set" do
      expect(create_user.api_key_present?).to be false
    end
  end

  describe "magic link tokens" do
    it "generates a token that can be looked up" do
      user = create_user
      raw_token = user.generate_login_token!

      expect(raw_token).to be_present
      expect(User.find_by_login_token(raw_token)).to eq(user)
    end

    it "returns nil for a token that was never issued" do
      create_user.generate_login_token!
      expect(User.find_by_login_token("wrong-token")).to be_nil
    end

    it "returns nil once the token has expired" do
      user = create_user
      raw_token = user.generate_login_token!

      travel(User::TOKEN_EXPIRY + 1.minute) do
        expect(User.find_by_login_token(raw_token)).to be_nil
      end
    end

    it "returns nil after the token is cleared" do
      user = create_user
      raw_token = user.generate_login_token!
      user.clear_login_token!

      expect(User.find_by_login_token(raw_token)).to be_nil
    end

    it "stores only a digest, never the raw token" do
      user = create_user
      raw_token = user.generate_login_token!

      expect(user.reload.login_token_digest).not_to include(raw_token)
    end
  end

  describe "#recent_performance sections_answered" do
    it "counts a section answered on the same terms the dashboard and history do" do
      user = create_user
      exercise = DailyExercise.create!(user: user, date: Date.current,
                                       problem_set: { "code_review" => {} }, generated_at: Time.current)
      daily_response = DailyResponse.create!(
        user: user, daily_exercise: exercise, date: Date.current,
        answers: { "code_review" => "Found the N+1 in the loop", "pattern" => " " * 20, "challenge" => "short" }
      )

      expect(user.recent_performance.first[:sections_answered])
        .to eq(daily_response.answered_sections.size)
    end
  end

  describe "#recent_performance concepts" do
    it "includes each session's concept_tags map, empty for untagged history" do
      user = create_user
      exercise = DailyExercise.create!(user: user, date: Date.current,
                                       problem_set: { "code_review" => {} }, generated_at: Time.current)
      DailyResponse.create!(user: user, daily_exercise: exercise, date: Date.current,
                            answers: { "code_review" => "x" * 20 },
                            concept_tags: { "code_review" => "memoization" })

      perf = user.recent_performance
      expect(perf.first[:concepts]).to eq({ "code_review" => "memoization" })
    end

    it "never yields nil concept_tags (column is NOT NULL with {} default)" do
      user = create_user
      exercise = DailyExercise.create!(user: user, date: Date.current,
                                       problem_set: { "code_review" => {} }, generated_at: Time.current)
      DailyResponse.create!(user: user, daily_exercise: exercise, date: Date.current,
                            answers: { "code_review" => "x" * 20 })

      expect(user.recent_performance.first[:concepts]).to eq({})

      expect {
        DailyResponse.connection.execute(
          "UPDATE daily_responses SET concept_tags = NULL"
        )
      }.to raise_error(ActiveRecord::StatementInvalid, /null value/i)
    end
  end

  describe "#language_for_today" do
    it "returns ruby_rails unchanged when the preference is ruby_rails" do
      user = create_user
      expect(user.language_for_today).to eq("ruby_rails")
    end

    it "returns javascript unchanged when the preference is javascript" do
      user = User.create!(email: "js@example.com", name: "JS", language: "javascript")
      expect(user.language_for_today).to eq("javascript")
    end

    it "defaults mixed to ruby_rails when there is no prior exercise" do
      user = User.create!(email: "mixed@example.com", name: "Mixed", language: "mixed")
      expect(user.language_for_today).to eq("ruby_rails")
    end

    it "flips from ruby_rails to javascript for mixed users based on the most recent prior exercise" do
      user = User.create!(email: "mixed2@example.com", name: "Mixed2", language: "mixed")
      DailyExercise.create!(user: user, date: Date.yesterday, problem_set: { "code_review" => {} },
                            generated_at: Time.current, language: "ruby_rails")

      expect(user.language_for_today).to eq("javascript")
    end

    it "flips from javascript to ruby_rails for mixed users based on the most recent prior exercise" do
      user = User.create!(email: "mixed3@example.com", name: "Mixed3", language: "mixed")
      DailyExercise.create!(user: user, date: Date.yesterday, problem_set: { "code_review" => {} },
                            generated_at: Time.current, language: "javascript")

      expect(user.language_for_today).to eq("ruby_rails")
    end

    it "ignores today's own exercise row when resolving alternation (regenerate-safe)" do
      user = User.create!(email: "mixed4@example.com", name: "Mixed4", language: "mixed")
      DailyExercise.create!(user: user, date: 2.days.ago.to_date, problem_set: { "code_review" => {} },
                            generated_at: Time.current, language: "ruby_rails")
      DailyExercise.create!(user: user, date: Date.current, problem_set: { "code_review" => {} },
                            generated_at: Time.current, language: "javascript")

      expect(user.language_for_today).to eq("javascript")
    end
  end

  describe "#effective_time_zone and time_zone validation" do
    it "returns the stored zone when set" do
      user = create_user
      user.time_zone = "America/Los_Angeles"
      expect(user.effective_time_zone).to eq("America/Los_Angeles")
    end

    it "falls back to America/New_York when the zone is blank" do
      user = create_user
      user.time_zone = nil
      expect(user.effective_time_zone).to eq("America/New_York")
    end

    it "accepts an IANA zone name and a Rails friendly name, and nil" do
      expect(User.new(email: "z1@example.com", name: "Z", time_zone: "America/Chicago")).to be_valid
      expect(User.new(email: "z2@example.com", name: "Z", time_zone: "Pacific Time (US & Canada)")).to be_valid
      expect(User.new(email: "z3@example.com", name: "Z", time_zone: nil)).to be_valid
    end

    it "accepts IANA zones outside Rails' MAPPING subset (regression: Alaska/Michigan browsers and manual select)" do
      expect(User.new(email: "z5@example.com", name: "Z", time_zone: "America/Anchorage")).to be_valid
      expect(User.new(email: "z6@example.com", name: "Z", time_zone: "America/Detroit")).to be_valid
    end

    it "rejects a garbage zone" do
      user = User.new(email: "z4@example.com", name: "Z", time_zone: "Mars/Phobos")
      expect(user).not_to be_valid
      expect(user.errors[:time_zone]).to be_present
    end
  end

  describe "#provider_label" do
    it "returns Claude for the anthropic provider" do
      user = create_user
      user.provider = "anthropic"
      expect(user.provider_label).to eq("Claude")
    end

    it "returns Gemini for the gemini provider" do
      user = create_user
      user.provider = "gemini"
      expect(user.provider_label).to eq("Gemini")
    end

    it "falls back to AI when the provider is nil" do
      user = create_user
      user.provider = nil
      expect(user.provider_label).to eq("AI")
    end

    it "falls back to AI for an unexpected provider value (e.g. legacy data)" do
      # Validations block writing this normally, but rows can reach the DB via
      # update_column/insert_all/raw SQL — the label must stay stable, never a
      # user-visible "translation missing".
      user = create_user
      user.provider = "openai"
      expect(user.provider_label).to eq("AI")
    end
  end
end
