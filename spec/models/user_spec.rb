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
end
