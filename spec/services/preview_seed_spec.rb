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
  end
end
