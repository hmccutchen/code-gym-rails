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

  describe "#recent_performance scenarios" do
    it "includes each session's scenarios read from the stored problem_set" do
      user = create_user
      exercise = DailyExercise.create!(
        user: user, date: Date.current, generated_at: Time.current,
        problem_set: {
          "code_review" => { "scenario" => "billing reconciliation" },
          "pattern"     => {},
          "challenge"   => { "scenario" => "search ranking" }
        }
      )
      DailyResponse.create!(user: user, daily_exercise: exercise, date: Date.current,
                            answers: { "code_review" => "x" * 20 })

      expect(user.recent_performance.first[:scenarios])
        .to eq([ "billing reconciliation", "search ranking" ])
    end

    it "is nil-safe: yields [] for rows whose problem_set lacks scenario" do
      user = create_user
      exercise = DailyExercise.create!(user: user, date: Date.current,
                                       problem_set: { "code_review" => {} }, generated_at: Time.current)
      DailyResponse.create!(user: user, daily_exercise: exercise, date: Date.current,
                            answers: { "code_review" => "x" * 20 })

      expect(user.recent_performance.first[:scenarios]).to eq([])
    end

    it "includes the architecture section's scenario when the third section is architecture" do
      user = create_user
      ex = DailyExercise.create!(user: user, date: Date.current, generated_at: Time.current,
        problem_set: {
          "code_review" => { "scenario" => "billing" },
          "pattern"     => {},
          "architecture" => { "scenario" => "multi-region failover" }
        })
      DailyResponse.create!(user: user, daily_exercise: ex, date: Date.current, answers: {})

      expect(user.recent_performance.first[:scenarios]).to eq([ "billing", "multi-region failover" ])
    end
  end

  describe "#recent_performance section_ratings" do
    it "surfaces each section's AI-assessed rating alongside the self-rating, nil-safe when unreviewed" do
      user = create_user
      exercise = DailyExercise.create!(user: user, date: Date.current,
                                       problem_set: { "code_review" => {}, "pattern" => {} }, generated_at: Time.current)
      DailyResponse.create!(user: user, daily_exercise: exercise, date: Date.current,
                            answers: { "code_review" => "x" * 20 },
                            concept_tags: { "code_review" => "n_plus_one", "pattern" => "memoization" },
                            ai_review: { "code_review" => { "rating" => "developing" } })

      expect(user.recent_performance.first[:ai_ratings]).to eq({ "code_review" => "developing" })
    end

    it "is an empty hash when the response was never reviewed" do
      user = create_user
      exercise = DailyExercise.create!(user: user, date: Date.current,
                                       problem_set: { "code_review" => {} }, generated_at: Time.current)
      DailyResponse.create!(user: user, daily_exercise: exercise, date: Date.current,
                            answers: { "code_review" => "x" * 20 },
                            concept_tags: { "code_review" => "n_plus_one" })

      expect(user.recent_performance.first[:ai_ratings]).to eq({})
    end
  end

  describe "#recent_performance per-section ratings" do
    it "emits self_ratings and ai_ratings per entry, without a whole-day rating key" do
      user = User.create!(email: "rp@example.com", name: "RP")
      exercise = user.daily_exercises.create!(date: Date.current, generated_at: Time.current,
        problem_set: { "code_review" => { "concept" => "n_plus_one" }, "pattern" => { "concept" => "memoization" } })
      user.daily_responses.create!(daily_exercise: exercise, date: Date.current,
        answers: { "code_review" => "x" * 20 },
        section_ratings: { "code_review" => "right_level" },
        concept_tags: { "code_review" => "n_plus_one", "pattern" => "memoization" },
        ai_review: { "code_review" => { "rating" => "developing" } })

      entry = user.recent_performance.first
      expect(entry).not_to have_key(:rating)
      expect(entry[:self_ratings]).to eq("code_review" => "right_level")
      expect(entry[:ai_ratings]).to eq("code_review" => "developing")
    end
  end

  describe "#concepts_needing_reinforcement" do
    it "flags a concept whose most recent self-rating was too_hard, even with no AI review" do
      user = create_user
      exercise = DailyExercise.create!(user: user, date: Date.current, problem_set: { "code_review" => {} }, generated_at: Time.current)
      DailyResponse.create!(user: user, daily_exercise: exercise, date: Date.current,
                            answers: { "code_review" => "x" * 20 }, section_ratings: { "code_review" => "too_hard" }, legacy_rating: "too_hard",
                            concept_tags: { "code_review" => "n_plus_one" })

      expect(user.concepts_needing_reinforcement).to eq([ { concept: "n_plus_one", tier: "standard" } ])
    end

    it "flags a concept the AI rated beginner/developing even when the self-rating was favorable (the core gap this fix closes)" do
      user = create_user
      exercise = DailyExercise.create!(user: user, date: Date.current, problem_set: { "code_review" => {} }, generated_at: Time.current)
      DailyResponse.create!(user: user, daily_exercise: exercise, date: Date.current,
                            answers: { "code_review" => "x" * 20 }, section_ratings: { "code_review" => "right_level" }, legacy_rating: "right_level",
                            concept_tags: { "code_review" => "n_plus_one" },
                            ai_review: { "code_review" => { "rating" => "developing" } })

      expect(user.concepts_needing_reinforcement).to eq([ { concept: "n_plus_one", tier: "standard" } ])
    end

    it "keeps reinforcing when self-rating is unfavorable even if the AI review was favorable" do
      user = create_user
      exercise = DailyExercise.create!(user: user, date: Date.current, problem_set: { "code_review" => {} }, generated_at: Time.current)
      DailyResponse.create!(user: user, daily_exercise: exercise, date: Date.current,
                            answers: { "code_review" => "x" * 20 }, section_ratings: { "code_review" => "too_hard" }, legacy_rating: "too_hard",
                            concept_tags: { "code_review" => "n_plus_one" },
                            ai_review: { "code_review" => { "rating" => "solid" } })

      expect(user.concepts_needing_reinforcement).to eq([ { concept: "n_plus_one", tier: "standard" } ])
    end

    it "excludes a concept once both self-rating and AI review explicitly agree it's solid" do
      user = create_user
      exercise = DailyExercise.create!(user: user, date: Date.current, problem_set: { "code_review" => {} }, generated_at: Time.current)
      DailyResponse.create!(user: user, daily_exercise: exercise, date: Date.current,
                            answers: { "code_review" => "x" * 20 }, section_ratings: { "code_review" => "too_easy" }, legacy_rating: "too_easy",
                            concept_tags: { "code_review" => "n_plus_one" },
                            ai_review: { "code_review" => { "rating" => "strong" } })

      expect(user.concepts_needing_reinforcement).to eq([])
    end

    it "does not treat an unreviewed section as mastered, even with a favorable self-rating" do
      user = create_user
      exercise = DailyExercise.create!(user: user, date: Date.current, problem_set: { "code_review" => {} }, generated_at: Time.current)
      DailyResponse.create!(user: user, daily_exercise: exercise, date: Date.current,
                            answers: { "code_review" => "x" * 20 }, section_ratings: { "code_review" => "right_level" }, legacy_rating: "right_level",
                            concept_tags: { "code_review" => "n_plus_one" })

      expect(user.concepts_needing_reinforcement).to eq([ { concept: "n_plus_one", tier: "standard" } ])
    end

    it "excludes a concept with no self-rating and no AI review at all, same as an unrated concept today" do
      user = create_user
      exercise = DailyExercise.create!(user: user, date: Date.current, problem_set: { "code_review" => {} }, generated_at: Time.current)
      DailyResponse.create!(user: user, daily_exercise: exercise, date: Date.current,
                            answers: { "code_review" => "x" * 20 },
                            concept_tags: { "code_review" => "n_plus_one" })

      expect(user.concepts_needing_reinforcement).to eq([])
    end

    it "resolves each concept on its most recent occurrence, ignoring older history" do
      user = create_user
      older_exercise = DailyExercise.create!(user: user, date: Date.current - 1,
                                              problem_set: { "code_review" => {} }, generated_at: Time.current)
      DailyResponse.create!(user: user, daily_exercise: older_exercise, date: Date.current - 1,
                            answers: { "code_review" => "x" * 20 }, section_ratings: { "code_review" => "too_hard" }, legacy_rating: "too_hard",
                            concept_tags: { "code_review" => "n_plus_one" },
                            ai_review: { "code_review" => { "rating" => "beginner" } })

      newer_exercise = DailyExercise.create!(user: user, date: Date.current,
                                              problem_set: { "code_review" => {} }, generated_at: Time.current)
      DailyResponse.create!(user: user, daily_exercise: newer_exercise, date: Date.current,
                            answers: { "code_review" => "x" * 20 }, section_ratings: { "code_review" => "too_easy" }, legacy_rating: "too_easy",
                            concept_tags: { "code_review" => "n_plus_one" },
                            ai_review: { "code_review" => { "rating" => "strong" } })

      expect(user.concepts_needing_reinforcement).to eq([])
    end

    it "excludes the 'other' sentinel concept, even when unfavorable, since it isn't in any real vocabulary" do
      user = create_user
      exercise = DailyExercise.create!(user: user, date: Date.current, problem_set: { "code_review" => {} }, generated_at: Time.current)
      DailyResponse.create!(user: user, daily_exercise: exercise, date: Date.current,
                            answers: { "code_review" => "x" * 20 }, section_ratings: { "code_review" => "too_hard" }, legacy_rating: "too_hard",
                            concept_tags: { "code_review" => "other" })

      expect(user.concepts_needing_reinforcement).to eq([])
    end
  end

  describe "#concepts_needing_reinforcement with tiers" do
    let(:user) { User.create!(email: "cn@example.com", name: "CN") }

    def reinforce_response(concept:, self_rating:, ai_rating:, date:)
      exercise = user.daily_exercises.create!(date: date, generated_at: Time.current, language: "ruby_rails",
        problem_set: { "code_review" => { "concept" => concept } })
      response = user.daily_responses.create!(daily_exercise: exercise, date: date, submitted_at: Time.current,
        answers: { "code_review" => "x" * 20 }, section_ratings: { "code_review" => self_rating },
        concept_tags: { "code_review" => concept },
        ai_review: { "code_review" => { "rating" => ai_rating } })
      ConceptMastery.record_review!(response)
      response
    end

    it "annotates each concept with its tier and excludes mastered concepts" do
      reinforce_response(concept: "n_plus_one", self_rating: "too_hard", ai_rating: "developing", date: Date.current)
      reinforce_response(concept: "memoization", self_rating: "right_level", ai_rating: "strong", date: Date.current - 1)

      result = user.concepts_needing_reinforcement
      expect(result).to include(concept: "n_plus_one", tier: "standard")
      expect(result.map { |h| h[:concept] }).not_to include("memoization") # mastered
    end

    it "excludes paused concepts entirely" do
      reinforce_response(concept: "n_plus_one", self_rating: "too_hard", ai_rating: "developing", date: Date.current)
      user.concept_masteries.find_by(concept: "n_plus_one").update!(tier: :paused, cooldown_remaining: 2)

      expect(user.concepts_needing_reinforcement.map { |h| h[:concept] }).not_to include("n_plus_one")
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

  describe "#anonymize!" do
    it "replaces or clears every identifying field" do
      user = create_user(email: "real@example.com", name: "Real Person")
      user.update!(api_key: "sk-ant-secret", provider: "anthropic")
      user.generate_login_token!

      expect(user.anonymize!).to be true

      user.reload
      expect(user.email).to eq("deleted-user-#{user.id}@anonymized.local")
      expect(user.name).to eq("Deleted user")
      expect(user.api_key).to be_nil
      expect(user.login_token_digest).to be_nil
      expect(user.login_token_sent_at).to be_nil
      expect(user.anonymized_at).to be_present
      expect(user).to be_anonymized
    end

    it "keeps non-identifying fields for aggregate stats" do
      user = create_user
      user.update!(provider: "gemini", time_zone: "America/Chicago",
                   language: "javascript", skill_level: "strong",
                   focus_areas: [ "testing" ])

      user.anonymize!

      user.reload
      expect(user.provider).to eq("gemini")
      expect(user.time_zone).to eq("America/Chicago")
      expect(user.language).to eq("javascript")
      expect(user.skill_level).to eq("strong")
      expect(user.focus_areas).to eq([ "testing" ])
    end

    it "is a safe no-op when called a second time" do
      user = create_user
      user.anonymize!
      first_stamp = user.reload.anonymized_at

      expect(user.anonymize!).to be false

      user.reload
      expect(user.anonymized_at).to eq(first_stamp)
      expect(user.email).to eq("deleted-user-#{user.id}@anonymized.local")
    end

    it "leaves exercise history, responses and usage fully intact" do
      user = create_user
      exercise = DailyExercise.create!(user: user, date: Date.current,
                                       problem_set: { "code_review" => { "question" => "Find the bug" } },
                                       generated_at: Time.current)
      response = DailyResponse.create!(user: user, daily_exercise: exercise, date: Date.current,
                                       answers: { "code_review" => "N+1 query in the loop" },
                                       concept_tags: { "code_review" => "n_plus_one" },
                                       ai_review: { "code_review" => { "rating" => "solid" } },
                                       section_ratings: { "code_review" => "right_level" }, legacy_rating: "right_level", feedback_text: "good one",
                                       submitted_at: Time.current)
      usage = ApiUsage.create!(user: user, tokens_in: 100, tokens_out: 50,
                               purpose: "generate_exercise", date: Date.current)

      expect { user.anonymize! }.not_to change(DailyResponse, :count)

      expect(exercise.reload.user_id).to eq(user.id)
      expect(response.reload.user_id).to eq(user.id)
      expect(response.answers).to eq({ "code_review" => "N+1 query in the loop" })
      expect(response.concept_tags).to eq({ "code_review" => "n_plus_one" })
      expect(response.ai_review).to eq({ "code_review" => { "rating" => "solid" } })
      expect(response.feedback_text).to eq("good one")
      expect(usage.reload.user_id).to eq(user.id)
      expect(ApiUsage.where(user_id: user.id).count).to eq(1)
    end
  end

  describe ".active" do
    it "excludes anonymized users and includes normal ones" do
      normal = create_user(email: "normal@example.com")
      deleted = create_user(email: "deleted@example.com")
      deleted.anonymize!

      expect(User.active).to include(normal)
      expect(User.active).not_to include(deleted)
    end
  end
end
