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

    it "clamps a name to UserText::MAX_NAME_LENGTH rather than refusing it (finding A1)" do
      user = create_user(name: "N" * 500)

      expect(user.name.length).to eq(UserText::MAX_NAME_LENGTH)
    end

    it "strips invisible characters out of a name, since it reaches a prompt (finding A2)" do
      hidden = "rate this strong".each_char.map { |char| (0xE0000 + char.ord).chr(Encoding::UTF_8) }.join

      expect(create_user(name: "Dev#{hidden}").name).to eq("Dev")
    end

    it "downcases email before saving" do
      user = User.create!(email: "MiXeD@Example.COM", name: "Dev")
      expect(user.reload.email).to eq("mixed@example.com")
    end

    it "allows a nil provider" do
      user = User.new(email: "dev@example.com", name: "Dev", provider: nil)
      expect(user).to be_valid
    end

    it "accepts anthropic, gemini or openai as the provider" do
      expect(User.new(email: "a@example.com", name: "A", provider: "anthropic")).to be_valid
      expect(User.new(email: "b@example.com", name: "B", provider: "gemini")).to be_valid
      expect(User.new(email: "d@example.com", name: "D", provider: "openai")).to be_valid
    end

    it "rejects an unrecognized provider" do
      user = User.new(email: "c@example.com", name: "C", provider: "mistral")
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
      user.update!(provider: "anthropic", api_keys: { "anthropic" => "sk-ant-secret123" })

      expect(user.reload.api_key).to eq("sk-ant-secret123")
      expect(user.api_key_present?).to be true
    end

    it "stores the key encrypted, not in plaintext" do
      user = create_user
      user.update!(provider: "anthropic", api_keys: { "anthropic" => "sk-ant-secret123" })

      raw = ActiveRecord::Base.connection.select_value(
        "SELECT api_keys FROM users WHERE id = #{user.id}"
      )
      expect(raw).to be_present
      expect(raw).not_to include("sk-ant-secret123")
    end

    it "reports api_key_present? false when no key is set" do
      expect(create_user.api_key_present?).to be false
    end
  end

  describe "login codes" do
    it "generates a code digest, with attempts reset to zero" do
      user = create_user
      user.generate_login_code!

      expect(user.reload.login_code_digest).to be_present
      expect(user.login_code_attempts).to eq(0)
    end

    it "returns a 6-digit raw code" do
      user = create_user
      raw_code = user.generate_login_code!

      expect(raw_code).to match(/\A\d{6}\z/)
    end

    it "stores only a digest, never the raw code" do
      user = create_user
      raw_code = user.generate_login_code!

      digest = user.reload.login_code_digest
      expect(digest).not_to eq(raw_code)
      expect(BCrypt::Password.new(digest)).to eq(raw_code)
    end

    it "authenticates with the correct code and invalidates it" do
      user = create_user
      raw_code = user.generate_login_code!

      expect(User.authenticate_login_code(email: user.email, code: raw_code)).to eq(user)
      expect(user.reload.login_code_digest).to be_nil
    end

    it "returns nil and increments attempts for a wrong code" do
      user = create_user
      raw_code = user.generate_login_code!

      expect(User.authenticate_login_code(email: user.email, code: wrong_code_for(raw_code))).to be_nil
      expect(user.reload.login_code_attempts).to eq(1)
      expect(user.login_code_digest).to be_present
    end

    it "locks out and invalidates the code after 5 wrong attempts" do
      user = create_user
      raw_code = user.generate_login_code!
      wrong = wrong_code_for(raw_code)

      4.times { User.authenticate_login_code(email: user.email, code: wrong) }
      expect(user.reload.login_code_digest).to be_present

      User.authenticate_login_code(email: user.email, code: wrong)
      expect(user.reload.login_code_digest).to be_nil
    end

    it "invalidates the code once it has already been used" do
      user = create_user
      raw_code = user.generate_login_code!

      user.clear_login_code!

      expect(User.authenticate_login_code(email: user.email, code: raw_code)).to be_nil
    end

    it "expires the code after LOGIN_CODE_EXPIRY" do
      user = create_user
      raw_code = user.generate_login_code!

      travel(User::LOGIN_CODE_EXPIRY + 1.minute) do
        expect(User.authenticate_login_code(email: user.email, code: raw_code)).to be_nil
      end
    end

    it "returns nil for an email with no pending login" do
      create_user
      expect(User.authenticate_login_code(email: "nobody@example.com", code: "123456")).to be_nil
    end

    it "clears the code when the account is anonymized" do
      user = create_user
      user.generate_login_code!

      user.anonymize!

      expect(user.reload.login_code_digest).to be_nil
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

  describe "#recent_performance answered_sections" do
    it "carries the day's answered sections so the prompt can label a skipped one" do
      user = create_user
      exercise = DailyExercise.create!(user: user, date: Date.current,
                                       problem_set: { "code_review" => {}, "pattern" => {} }, generated_at: Time.current)
      daily_response = DailyResponse.create!(
        user: user, daily_exercise: exercise, date: Date.current,
        answers: { "code_review" => "Found the N+1 in the loop", "pattern" => "" }
      )

      expect(user.recent_performance.first[:answered_sections]).to eq(daily_response.answered_sections)
    end
  end

  describe "#recent_performance sections_total" do
    it "reports the historical exercise's own section count" do
      user = User.create!(email: "sections-total@example.com", name: "Total")
      exercise = DailyExercise.create!(user: user, date: Date.current, generated_at: Time.current,
                                       problem_set: { "code_review" => {}, "pattern" => {}, "challenge" => {}, "plan_review" => {} })
      DailyResponse.create!(user: user, daily_exercise: exercise, date: exercise.date, submitted_at: Time.current,
                            answers: { "code_review" => "a" * 20 })

      expect(user.recent_performance.first[:sections_total]).to eq(4)
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

    it "includes a security_review section's scenario in recent_performance's framings" do
      user = create_user
      exercise = DailyExercise.create!(
        user: user, date: Date.current - 1, generated_at: Time.current,
        problem_set: { "security_review" => { "scenario" => "a legacy GraphQL layer needs a fix" } }
      )
      DailyResponse.create!(user: user, daily_exercise: exercise, date: Date.current - 1,
                            answers: { "security_review" => "x" * 20 })

      performance = user.recent_performance
      expect(performance.first[:scenarios]).to include("a legacy GraphQL layer needs a fix")
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

    it "leaves a skipped section's AI grade out of ai_ratings while still listing its concept" do
      user = create_user
      exercise = DailyExercise.create!(user: user, date: Date.current,
                                       problem_set: { "code_review" => {}, "pattern" => {} }, generated_at: Time.current)
      DailyResponse.create!(user: user, daily_exercise: exercise, date: Date.current,
                            answers: { "code_review" => "x" * 20, "pattern" => "" },
                            concept_tags: { "code_review" => "n_plus_one", "pattern" => "memoization" },
                            ai_review: { "code_review" => { "rating" => "developing" },
                                         "pattern"     => { "rating" => "beginner" } })

      entry = user.recent_performance.first
      expect(entry[:ai_ratings]).to eq("code_review" => "developing")
      expect(entry[:concepts]).to eq("code_review" => "n_plus_one", "pattern" => "memoization")
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

    it "keeps a skipped section's self-rating in self_ratings" do
      user = create_user
      exercise = DailyExercise.create!(user: user, date: Date.current,
                                       problem_set: { "code_review" => {}, "pattern" => {} }, generated_at: Time.current)
      DailyResponse.create!(user: user, daily_exercise: exercise, date: Date.current,
                            answers: { "code_review" => "x" * 20, "pattern" => "" },
                            section_ratings: { "code_review" => "right_level", "pattern" => "too_easy" },
                            concept_tags: { "code_review" => "n_plus_one", "pattern" => "memoization" })

      expect(user.recent_performance.first[:self_ratings]).to eq(
        "code_review" => "right_level", "pattern" => "too_easy"
      )
    end
  end

  describe "#recent_exercise_history" do
    let(:user) { User.create!(email: "history@example.com", name: "History") }

    def exercise_on(date, keys, answers: nil)
      problem_set = keys.index_with { |key| { "question" => "q" } }
      exercise = DailyExercise.create!(user: user, date: date, language: "ruby_rails",
                                       generated_at: Time.current, problem_set: problem_set)
      DailyResponse.create!(user: user, daily_exercise: exercise, date: date, answers: answers) if answers
      exercise
    end

    it "reports nil answered for an exercise that was never opened" do
      exercise_on(Date.current - 1, %w[code_review pattern])

      expect(user.recent_exercise_history(limit: 5).first.answered).to be_nil
    end

    it "counts an autosaved draft's answered sections rather than treating it as skipped" do
      exercise_on(Date.current - 1, %w[code_review pattern],
                  answers: { "code_review" => "a real answer well past ten characters" })

      expect(user.recent_exercise_history(limit: 5).first.answered).to eq(1)
    end

    it "excludes today, which has had no chance to be answered" do
      exercise_on(Date.current, %w[code_review pattern])
      exercise_on(Date.current - 1, %w[code_review challenge])

      expect(user.recent_exercise_history(limit: 5).map(&:section_keys))
        .to eq([ %w[code_review challenge] ])
    end

    it "returns newest first" do
      exercise_on(Date.current - 1, %w[code_review pattern])
      exercise_on(Date.current - 2, %w[code_review challenge])

      expect(user.recent_exercise_history(limit: 5).first.section_keys).to eq(%w[code_review pattern])
    end
  end

  describe "#concepts_needing_reinforcement" do
    it "flags a concept whose most recent self-rating was too_hard, even with no AI review" do
      user = create_user
      exercise = DailyExercise.create!(user: user, date: Date.current, problem_set: { "code_review" => {} }, generated_at: Time.current)
      DailyResponse.create!(user: user, daily_exercise: exercise, date: Date.current,
                            answers: { "code_review" => "x" * 20 }, section_ratings: { "code_review" => "too_hard" }, legacy_rating: "too_hard",
                            concept_tags: { "code_review" => "n_plus_one" })

      expect(user.concepts_needing_reinforcement).to eq([ { concept: "n_plus_one", bucket: "ruby_rails", tier: "standard" } ])
    end

    it "flags a concept the AI rated beginner/developing even when the self-rating was favorable (the core gap this fix closes)" do
      user = create_user
      exercise = DailyExercise.create!(user: user, date: Date.current, problem_set: { "code_review" => {} }, generated_at: Time.current)
      DailyResponse.create!(user: user, daily_exercise: exercise, date: Date.current,
                            answers: { "code_review" => "x" * 20 }, section_ratings: { "code_review" => "right_level" }, legacy_rating: "right_level",
                            concept_tags: { "code_review" => "n_plus_one" },
                            ai_review: { "code_review" => { "rating" => "developing" } })

      expect(user.concepts_needing_reinforcement).to eq([ { concept: "n_plus_one", bucket: "ruby_rails", tier: "standard" } ])
    end

    it "skips a tagged concept that is no longer in its bucket's vocabulary, so it can't reinforce forever and block a retention check" do
      user = create_user
      exercise = DailyExercise.create!(user: user, date: Date.current, problem_set: { "code_review" => {} }, generated_at: Time.current)
      DailyResponse.create!(user: user, daily_exercise: exercise, date: Date.current,
                            answers: { "code_review" => "x" * 20 }, section_ratings: { "code_review" => "too_hard" }, legacy_rating: "too_hard",
                            concept_tags: { "code_review" => "retired_concept" })

      expect(user.concepts_needing_reinforcement).to eq([])
    end

    it "does not let an out-of-vocabulary occurrence hide an older one in a bucket where the name is still valid" do
      user = create_user
      older = DailyExercise.create!(user: user, date: Date.current - 1, language: "ruby_rails",
                                    problem_set: { "code_review" => {} }, generated_at: Time.current)
      DailyResponse.create!(user: user, daily_exercise: older, date: Date.current - 1,
                            answers: { "code_review" => "x" * 20 }, section_ratings: { "code_review" => "too_hard" }, legacy_rating: "too_hard",
                            concept_tags: { "code_review" => "n_plus_one" })

      newer = DailyExercise.create!(user: user, date: Date.current, language: "javascript",
                                    problem_set: { "code_review" => {} }, generated_at: Time.current)
      DailyResponse.create!(user: user, daily_exercise: newer, date: Date.current,
                            answers: { "code_review" => "x" * 20 }, section_ratings: { "code_review" => "too_easy" }, legacy_rating: "too_easy",
                            concept_tags: { "code_review" => "n_plus_one" })

      expect(user.concepts_needing_reinforcement).to eq([ { concept: "n_plus_one", bucket: "ruby_rails", tier: "standard" } ])
    end

    it "keeps reinforcing when self-rating is unfavorable even if the AI review was favorable" do
      user = create_user
      exercise = DailyExercise.create!(user: user, date: Date.current, problem_set: { "code_review" => {} }, generated_at: Time.current)
      DailyResponse.create!(user: user, daily_exercise: exercise, date: Date.current,
                            answers: { "code_review" => "x" * 20 }, section_ratings: { "code_review" => "too_hard" }, legacy_rating: "too_hard",
                            concept_tags: { "code_review" => "n_plus_one" },
                            ai_review: { "code_review" => { "rating" => "solid" } })

      expect(user.concepts_needing_reinforcement).to eq([ { concept: "n_plus_one", bucket: "ruby_rails", tier: "standard" } ])
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

      expect(user.concepts_needing_reinforcement).to eq([ { concept: "n_plus_one", bucket: "ruby_rails", tier: "standard" } ])
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

    it "does not flag a concept whose only occurrence was a skipped section" do
      user = create_user
      exercise = DailyExercise.create!(user: user, date: Date.current, problem_set: { "code_review" => {} }, generated_at: Time.current)
      DailyResponse.create!(user: user, daily_exercise: exercise, date: Date.current,
                            answers: { "code_review" => "" },
                            concept_tags: { "code_review" => "n_plus_one" },
                            ai_review: { "code_review" => { "rating" => "beginner" } })

      expect(user.concepts_needing_reinforcement).to eq([])
    end

    it "lets an older answered occurrence decide when the newer one was skipped" do
      user = create_user
      older = DailyExercise.create!(user: user, date: Date.current - 2, problem_set: { "code_review" => {} }, generated_at: Time.current)
      DailyResponse.create!(user: user, daily_exercise: older, date: Date.current - 2,
                            answers: { "code_review" => "x" * 20 }, section_ratings: { "code_review" => "right_level" },
                            concept_tags: { "code_review" => "n_plus_one" },
                            ai_review: { "code_review" => { "rating" => "strong" } })
      newer = DailyExercise.create!(user: user, date: Date.current - 1, problem_set: { "code_review" => {} }, generated_at: Time.current)
      DailyResponse.create!(user: user, daily_exercise: newer, date: Date.current - 1,
                            answers: { "code_review" => "" },
                            concept_tags: { "code_review" => "n_plus_one" },
                            ai_review: { "code_review" => { "rating" => "beginner" } })

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
      ConceptMastery.record_review!(response, sections: response.concept_tags.keys, apply_session_countdown: true)
      response
    end

    it "annotates each concept with its tier and excludes mastered concepts" do
      reinforce_response(concept: "n_plus_one", self_rating: "too_hard", ai_rating: "developing", date: Date.current)
      reinforce_response(concept: "memoization", self_rating: "right_level", ai_rating: "strong", date: Date.current - 1)

      result = user.concepts_needing_reinforcement
      expect(result).to include(concept: "n_plus_one", bucket: "ruby_rails", tier: "standard")
      expect(result.map { |h| h[:concept] }).not_to include("memoization")
    end

    it "excludes paused concepts entirely" do
      reinforce_response(concept: "n_plus_one", self_rating: "too_hard", ai_rating: "developing", date: Date.current)
      user.concept_masteries.find_by(concept: "n_plus_one").update!(tier: :paused, cooldown_remaining: 2)

      expect(user.concepts_needing_reinforcement.map { |h| h[:concept] }).not_to include("n_plus_one")
    end
  end

  describe "#concepts_needing_reinforcement with bucket filters" do
    let(:user) { User.create!(email: "bucket-filter@example.com", name: "Bucket") }

    def submit_response(concept:, section:, language: "ruby_rails", self_rating: "too_hard", ai_rating: "developing")
      # Strictly decreasing dates, since DailyExercise dates are unique per user.
      @next_response_date ||= Date.current
      @next_response_date -= 1
      exercise = DailyExercise.create!(
        user: user, date: @next_response_date, generated_at: Time.current, language: language,
        problem_set: { section => { "concept" => concept } }
      )
      DailyResponse.create!(
        user: user, daily_exercise: exercise, date: exercise.date, submitted_at: Time.current,
        answers: { section => "x" * 20 },
        section_ratings: { section => self_rating },
        concept_tags: { section => concept },
        ai_review: { section => { "rating" => ai_rating } }
      )
    end

    it "with bucket:, includes only concepts from that bucket" do
      submit_response(concept: "scope_creep", section: "plan_review")
      submit_response(concept: "n_plus_one", section: "code_review")

      result = user.concepts_needing_reinforcement(bucket: "plan_review")
      expect(result.map { |h| h[:concept] }).to eq([ "scope_creep" ])
    end

    it "with exclude_buckets:, drops concepts from those buckets" do
      submit_response(concept: "scope_creep", section: "plan_review")
      submit_response(concept: "n_plus_one", section: "code_review")

      result = user.concepts_needing_reinforcement(exclude_buckets: %w[plan_review ambiguity_hunt])
      expect(result.map { |h| h[:concept] }).to eq([ "n_plus_one" ])
    end

    it "with neither filter, behaves exactly as before" do
      submit_response(concept: "scope_creep", section: "plan_review")
      submit_response(concept: "n_plus_one", section: "code_review")

      result = user.concepts_needing_reinforcement
      expect(result.map { |h| h[:concept] }).to match_array(%w[scope_creep n_plus_one])
    end
  end

  describe "#concepts_due_for_retention_check_in" do
    let(:user) { User.create!(email: "due@example.com", name: "Due") }

    def mastery(concept:, bucket:, due_on:)
      user.concept_masteries.create!(concept: concept, language: bucket, tier: :standard,
                                     mastered_at: 1.month.ago,
                                     retention_interval_days: 7,
                                     next_retention_check_on: due_on)
    end

    it "returns every due concept in the buckets given, and nothing else" do
      mastery(concept: "n_plus_one",         bucket: "ruby_rails",   due_on: Date.current - 3)
      mastery(concept: "service_boundaries", bucket: "architecture", due_on: Date.current)
      mastery(concept: "closures",           bucket: "javascript",   due_on: Date.current - 5)
      mastery(concept: "memoization",        bucket: "ruby_rails",   due_on: Date.current + 4)

      result = user.concepts_due_for_retention_check_in(%w[ruby_rails architecture])
      expect(result.map(&:concept)).to match_array(%w[n_plus_one service_boundaries])
    end

    it "excludes concepts with no schedule" do
      user.concept_masteries.create!(concept: "caching", language: "ruby_rails", tier: :standard)
      expect(user.concepts_due_for_retention_check_in(%w[ruby_rails])).to be_empty
    end

    it "excludes a concept no longer in the bucket's vocabulary" do
      mastery(concept: "memoization",     bucket: "ruby_rails", due_on: Date.current - 3)
      mastery(concept: "retired_concept", bucket: "ruby_rails", due_on: Date.current - 30)

      expect(user.concepts_due_for_retention_check_in(%w[ruby_rails]).map(&:concept)).to eq(%w[memoization])
    end
  end

  describe "#concepts_overdue_for_retention_check" do
    let(:user) { User.create!(email: "overdue@example.com", name: "Overdue") }

    def mastery(concept:, bucket: "ruby_rails", due_on:, interval: 7)
      user.concept_masteries.create!(concept: concept, language: bucket, tier: :standard,
                                     mastered_at: 1.month.ago,
                                     retention_interval_days: interval,
                                     next_retention_check_on: due_on)
    end

    it "excludes a concept that is due but has not crossed its own interval's overdue threshold" do
      mastery(concept: "memoization", due_on: Date.current - 2, interval: 7)
      expect(user.concepts_overdue_for_retention_check(bucket: "ruby_rails")).to be_empty
    end

    it "includes a concept once it is overdue by its own full interval" do
      mastery(concept: "memoization", due_on: Date.current - 8, interval: 7)
      expect(user.concepts_overdue_for_retention_check(bucket: "ruby_rails").map(&:concept)).to eq(%w[memoization])
    end

    # Real vocabulary names: the query filters on membership, so invented names would pass for the wrong reason.
    it "scales the threshold with each concept's own interval, not a flat number" do
      mastery(concept: "memoization", due_on: Date.current - 8, interval: 7)
      mastery(concept: "n_plus_one",  due_on: Date.current - 8, interval: 28)
      expect(user.concepts_overdue_for_retention_check(bucket: "ruby_rails").map(&:concept)).to eq(%w[memoization])
    end

    it "excludes rows with a null retention_interval_days even when next_retention_check_on is far in the past" do
      user.concept_masteries.create!(concept: "indexing", language: "ruby_rails", tier: :standard,
                                     mastered_at: 1.month.ago,
                                     retention_interval_days: nil,
                                     next_retention_check_on: Date.current - 100)
      expect(user.concepts_overdue_for_retention_check(bucket: "ruby_rails")).to be_empty
    end

    it "excludes a concept no longer in the bucket's vocabulary, however overdue" do
      mastery(concept: "retired_concept", due_on: Date.current - 90, interval: 7)

      expect(user.concepts_overdue_for_retention_check(bucket: "ruby_rails")).to be_empty
    end

    it "filters by bucket" do
      mastery(concept: "closures", bucket: "javascript", due_on: Date.current - 8, interval: 7)
      expect(user.concepts_overdue_for_retention_check(bucket: "ruby_rails")).to be_empty
      expect(user.concepts_overdue_for_retention_check(bucket: "javascript").map(&:concept)).to eq(%w[closures])
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

  describe "provider keys" do
    it "keeps a key per provider and reads the one in use" do
      user = create_user
      user.store_api_key("sk-ant-one", provider: "anthropic")
      user.store_api_key("sk-proj-two", provider: "openai")
      user.save!

      user.reload
      expect(user.api_key).to eq("sk-proj-two")
      expect(user.stored_providers).to eq(%w[anthropic openai])
      user.update!(provider: "anthropic")
      expect(user.api_key).to eq("sk-ant-one")
    end

    it "lists stored providers in registry order whatever order they were saved in" do
      user = create_user
      user.store_api_key("sk-proj-two", provider: "openai")
      user.store_api_key("AIzaThree", provider: "gemini")
      user.store_api_key("sk-ant-one", provider: "anthropic")

      expect(user.stored_providers).to eq(AiProvider.keys & %w[anthropic gemini openai])
    end

    it "refuses selecting a provider with no stored key" do
      user = create_user
      user.update!(provider: "anthropic", api_keys: { "anthropic" => "sk-ant-one" })

      expect(user.update(provider: "openai")).to be false
      expect(user.errors[:provider]).to include("has no stored key")
    end

    it "refuses a key under an unknown provider or a blank key" do
      user = create_user

      expect(user.update(provider: "anthropic", api_keys: { "anthropic" => "sk-ant-one", "mistral" => "m" })).to be false
      expect(user.errors[:api_keys]).to include("names an unknown provider: mistral")
      expect(user.update(provider: "anthropic", api_keys: { "anthropic" => " " })).to be false
      expect(user.errors[:api_keys]).to include("has a blank key for anthropic")
    end

    it "records the old provider on unlabelled reviews before switching" do
      user = create_user
      user.update!(provider: "anthropic", api_keys: { "anthropic" => "sk-ant-one", "openai" => "sk-proj-two" })
      exercise = user.daily_exercises.create!(date: Date.new(2026, 9, 28), problem_set: { "code_review" => {} }, generated_at: Time.current)
      reviewed = user.daily_responses.create!(daily_exercise: exercise, date: exercise.date, submitted_at: Time.current,
                                              ai_review: { "code_review" => { "rating" => "solid" } })
      other_exercise = user.daily_exercises.create!(date: Date.new(2026, 9, 29), problem_set: { "code_review" => {} }, generated_at: Time.current)
      unreviewed = user.daily_responses.create!(daily_exercise: other_exercise, date: other_exercise.date, submitted_at: Time.current)

      user.update!(provider: "openai")

      expect(reviewed.reload.review_provider).to eq("anthropic")
      expect(reviewed.review_provider_label).to eq("Claude")
      expect(unreviewed.reload.review_provider).to be_nil
    end

    it "stores no keys as nil, so the batch's has-a-key query skips the account" do
      user = create_user
      user.update!(provider: "anthropic", api_keys: { "anthropic" => "sk-ant-one" })
      user.update!(api_keys: {})

      expect(user.reload.api_keys).to be_nil
      expect(User.where.not(api_keys: nil)).not_to include(user)
    end
  end

  describe "#skill_level" do
    it "reads each stored value from before skill levels took the difficulty levels' names as its new name" do
      user = create_user

      { "beginner" => "junior", "developing" => "junior", "solid" => "senior", "strong" => "principal_engineer" }.each do |stored, read|
        user.update_column(:skill_level, stored)
        expect(user.reload.skill_level).to eq(read)
      end
    end

    it "reads a new account, which the database still defaults to developing, as junior" do
      expect(create_user.reload.skill_level).to eq("junior")
    end

    it "leaves the stored value alone when another column is saved" do
      user = create_user
      user.update_column(:skill_level, "solid")

      user.reload.update!(name: "Renamed")

      expect(User.where(id: user.id).pick(:skill_level)).to eq("solid")
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

    it "returns GPT for the openai provider" do
      user = create_user
      user.provider = "openai"
      expect(user.provider_label).to eq("GPT")
    end

    it "falls back to AI when the provider is nil" do
      user = create_user
      user.provider = nil
      expect(user.provider_label).to eq("AI")
    end

    it "falls back to AI, never a missing translation, for an unexpected provider value (e.g. legacy data)" do
      user = create_user
      user.provider = "mistral"
      expect(user.provider_label).to eq("AI")
    end
  end

  describe "#anonymize!" do
    it "clears the legacy api_key column the migration left populated" do
      user = create_user(email: "legacy-key@example.com")
      user.update!(provider: "anthropic", api_keys: { "anthropic" => "sk-ant-secret" })
      ActiveRecord::Base.connection.execute("UPDATE users SET api_key = 'legacy-ciphertext' WHERE id = #{user.id}")

      user.anonymize!

      expect(ActiveRecord::Base.connection.select_value("SELECT api_key FROM users WHERE id = #{user.id}")).to be_nil
    end

    it "replaces or clears every identifying field" do
      user = create_user(email: "real@example.com", name: "Real Person")
      user.update!(provider: "anthropic", api_keys: { "anthropic" => "sk-ant-secret" })
      user.generate_login_code!

      expect(user.anonymize!).to be true

      user.reload
      expect(user.email).to eq("deleted-user-#{user.id}@anonymized.local")
      expect(user.name).to eq("Deleted user")
      expect(user.api_key).to be_nil
      expect(user.login_code_digest).to be_nil
      expect(user.login_code_sent_at).to be_nil
      expect(user.anonymized_at).to be_present
      expect(user).to be_anonymized
    end

    it "stops push reminders and drops the endpoints they would reach" do
      user = create_user
      user.update!(reminder_level: :ready)
      PushSubscription.register!(user: user, endpoint: "https://push.example.com/x", p256dh_key: "p", auth_key: "a")

      user.anonymize!

      expect(user.reload.reminders_none?).to be(true)
      expect(user.push_subscriptions).to be_empty
    end

    it "keeps non-identifying fields for aggregate stats" do
      user = create_user
      user.update!(provider: "gemini", time_zone: "America/Chicago",
                   language: "javascript", skill_level: "principal_engineer",
                   focus_areas: [ "testing" ])

      user.anonymize!

      user.reload
      expect(user.provider).to eq("gemini")
      expect(user.time_zone).to eq("America/Chicago")
      expect(user.language).to eq("javascript")
      expect(user.skill_level).to eq("principal_engineer")
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
                                       section_ratings: { "code_review" => "right_level" }, legacy_rating: "right_level",
                                       submitted_at: Time.current)
      usage = ApiUsage.create!(user: user, tokens_in: 100, tokens_out: 50,
                               purpose: "generate_exercise", date: Date.current)

      expect { user.anonymize! }.not_to change(DailyResponse, :count)

      expect(exercise.reload.user_id).to eq(user.id)
      expect(response.reload.user_id).to eq(user.id)
      expect(response.answers).to eq({ "code_review" => "N+1 query in the loop" })
      expect(response.concept_tags).to eq({ "code_review" => "n_plus_one" })
      expect(response.ai_review).to eq({ "code_review" => { "rating" => "solid" } })
      expect(usage.reload.user_id).to eq(user.id)
      expect(ApiUsage.where(user_id: user.id).count).to eq(1)
    end
  end

  describe "#paused_generation_at?" do
    it "is false when paused_generation_at is nil" do
      user = User.new(paused_generation_at: nil)
      expect(user.paused_generation_at?).to be false
    end

    it "is true when paused_generation_at is set" do
      user = User.new(paused_generation_at: Time.current)
      expect(user.paused_generation_at?).to be true
    end
  end

  describe "#resume_generation!" do
    include ActiveSupport::Testing::TimeHelpers

    let(:wednesday) { Time.utc(2026, 7, 22, 12) }

    let(:user) { User.create!(email: "resumer@example.com", name: "Resumer", time_zone: "UTC") }

    def pause_on(date)
      user.update!(paused_generation_at: date.in_time_zone(user.effective_time_zone) + 9.hours)
    end

    def exercise_on(date, **attrs)
      user.daily_exercises.create!(date: date, generated_at: Time.current,
                                   problem_set: { "code_review" => { "question" => "q" } }, **attrs)
    end

    it "clears the pause and re-dates the held exercise to today" do
      travel_to(wednesday) do
        held = exercise_on(Date.current - 1)
        pause_on(Date.current - 1)

        expect(user.resume_generation!).to eq(held)
        expect(user.reload.paused_generation_at).to be_nil
        expect(held.reload.date).to eq(Date.current)
      end
    end

    it "moves the draft response with its exercise" do
      travel_to(wednesday) do
        held = exercise_on(Date.current - 1)
        draft = user.daily_responses.create!(daily_exercise: held, date: Date.current - 1,
                                             answers: { "code_review" => "a partial answer here" })
        pause_on(Date.current - 1)

        user.resume_generation!

        expect(draft.reload.date).to eq(Date.current)
        expect(held.reload.daily_response).to eq(draft)
        expect(user.daily_responses.count).to eq(1)
      end
    end

    it "leaves a submitted exercise where it is" do
      travel_to(wednesday) do
        submitted = exercise_on(Date.current - 1)
        user.daily_responses.create!(daily_exercise: submitted, date: Date.current - 1,
                                     submitted_at: Time.current, answers: {})
        pause_on(Date.current - 1)

        expect(user.resume_generation!).to be_nil
        expect(submitted.reload.date).to eq(Date.current - 1)
      end
    end

    it "leaves an exercise abandoned before the pause where it is" do
      travel_to(wednesday) do
        abandoned = exercise_on(Date.current - 2)
        pause_on(Date.current - 1)

        expect(user.resume_generation!).to be_nil
        expect(abandoned.reload.date).to eq(Date.current - 2)
        expect(user.reload.paused_generation_at).to be_nil
      end
    end

    it "does not overwrite a set generated explicitly today while paused" do
      travel_to(wednesday) do
        held = exercise_on(Date.current - 1)
        today = exercise_on(Date.current)
        pause_on(Date.current - 1)

        expect(user.resume_generation!).to be_nil
        expect(held.reload.date).to eq(Date.current - 1)
        expect(today.reload.date).to eq(Date.current)
      end
    end

    it "clears a leftover regeneration claim, so a stranded job cannot adopt the set" do
      travel_to(wednesday) do
        held = exercise_on(Date.current - 1, regenerating_since: Time.current - 2.days)
        pause_on(Date.current - 1)

        user.resume_generation!

        expect(held.reload.regenerating_since).to be_nil
      end
    end

    it "clears regenerated_at, since the set now belongs to a new day" do
      travel_to(wednesday) do
        held = exercise_on(Date.current - 1, regenerated_at: Time.current - 1.day)
        pause_on(Date.current - 1)

        user.resume_generation!

        expect(held.reload.regenerated_at).to be_nil
      end
    end

    [ ActiveRecord::RecordNotUnique.new("duplicate key"),
      :record_invalid ].each do |failure|
      it "keeps the pause cleared when the move loses to #{failure.is_a?(Symbol) ? 'a date validation' : 'the unique index'}" do
        travel_to(wednesday) do
          held = exercise_on(Date.current - 1)
          pause_on(Date.current - 1)
          raised = if failure == :record_invalid
            invalid = DailyExercise.new
            invalid.errors.add(:date, :taken)
            ActiveRecord::RecordInvalid.new(invalid)
          else
            failure
          end
          allow_any_instance_of(DailyExercise).to receive(:update!).and_raise(raised)

          expect(user.resume_generation!).to be_nil

          expect(user.reload.paused_generation_at).to be_nil
          expect(held.reload.date).to eq(Date.current - 1)
        end
      end
    end

    it "still surfaces a validation failure that is not the date collision" do
      travel_to(wednesday) do
        exercise_on(Date.current - 1)
        pause_on(Date.current - 1)
        invalid = DailyExercise.new
        invalid.errors.add(:language, :inclusion)
        allow_any_instance_of(DailyExercise).to receive(:update!)
          .and_raise(ActiveRecord::RecordInvalid.new(invalid))

        expect { user.resume_generation! }.to raise_error(ActiveRecord::RecordInvalid)
      end
    end

    it "clears a same-day generation error the recovered set makes stale" do
      travel_to(wednesday) do
        held = exercise_on(Date.current - 1)
        pause_on(Date.current - 1)
        user.update!(last_generation_error_date: Date.current, last_generation_error: "Provider timed out")

        user.resume_generation!

        expect(held.reload.date).to eq(Date.current)
        expect(user.reload.last_generation_error_date).to be_nil
        expect(user.last_generation_error).to be_nil
      end
    end

    it "leaves an error from an earlier day alone" do
      travel_to(wednesday) do
        exercise_on(Date.current - 1)
        pause_on(Date.current - 1)
        user.update!(last_generation_error_date: Date.current - 4, last_generation_error: "Old failure")

        user.resume_generation!

        expect(user.reload.last_generation_error_date).to eq(Date.current - 4)
      end
    end

    it "resolves both today and the pause day in the user's zone, not the caller's" do
      tokyoite = User.create!(email: "tokyo@example.com", name: "Tokyo", time_zone: "Asia/Tokyo")
      tokyoite.update!(paused_generation_at: Time.utc(2026, 7, 21, 23)) # 08:00 on the 22nd in Tokyo
      held = tokyoite.daily_exercises.create!(date: Date.new(2026, 7, 22), generated_at: Time.current,
                                             problem_set: { "code_review" => { "question" => "q" } })

      Time.use_zone("UTC") { travel_to(Time.utc(2026, 7, 22, 20)) { tokyoite.resume_generation! } }

      expect(held.reload.date).to eq(Date.new(2026, 7, 23))
    end

    it "reads the pause day in the user's own zone, not the server's" do
      new_yorker = User.create!(email: "ny@example.com", name: "NY", time_zone: "America/New_York")
      # 22:00 on the 21st in New York, which is already the 22nd in UTC.
      new_yorker.update!(paused_generation_at: Time.utc(2026, 7, 22, 2))
      held = new_yorker.daily_exercises.create!(date: Date.new(2026, 7, 21), generated_at: Time.current,
                                               problem_set: { "code_review" => { "question" => "q" } })

      Time.use_zone(new_yorker.effective_time_zone) do
        travel_to(Time.utc(2026, 7, 22, 16)) { new_yorker.resume_generation! }
      end

      expect(held.reload.date).to eq(Date.new(2026, 7, 22))
    end

    it "no-ops on a second call, so a double-tapped Resume moves nothing twice" do
      travel_to(wednesday) do
        held = exercise_on(Date.current - 1)
        pause_on(Date.current - 1)

        expect(user.resume_generation!).to eq(held)
        expect(user.resume_generation!).to be_nil
        expect(held.reload.date).to eq(Date.current)
        expect(user.daily_exercises.count).to eq(1)
      end
    end

    it "is a no-op for a user who was never paused" do
      travel_to(wednesday) do
        untouched = exercise_on(Date.current - 1)

        expect(user.resume_generation!).to be_nil
        expect(untouched.reload.date).to eq(Date.current - 1)
      end
    end

    context "the signals the move exists to correct" do
      it "stops the held set reading as a skip in #recent_exercise_history" do
        travel_to(wednesday) do
          exercise_on(Date.current - 1)
          pause_on(Date.current - 1)

          expect(user.recent_exercise_history(limit: 20).map(&:answered)).to eq([ nil ])

          user.resume_generation!

          expect(user.recent_exercise_history(limit: 20)).to be_empty
        end
      end

      it "stops the held set breaking the streak" do
        travel_to(wednesday) do
          user.daily_responses.create!(daily_exercise: exercise_on(Date.current - 2),
                                       date: Date.current - 2, submitted_at: Time.current, answers: {})
          exercise_on(Date.current - 1)
          pause_on(Date.current - 1)

          expect(user.current_streak).to eq(0)

          user.resume_generation!

          expect(user.current_streak).to eq(1)
        end
      end
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

  describe "#concept_exposure_count" do
    let(:user) { User.create!(email: "ex@example.com", name: "Ex") }

    def submit(concept:, date:, language: "ruby_rails", section: "code_review")
      exercise = user.daily_exercises.create!(date: date, generated_at: Time.current, language: language,
        problem_set: { section => { "concept" => concept } })
      user.daily_responses.create!(daily_exercise: exercise, date: date, submitted_at: Time.current,
        answers: { section => "x" * 20 }, concept_tags: { section => concept })
    end

    it "counts occurrences within the same language bucket, on or before the given date" do
      submit(concept: "n_plus_one", date: Date.current - 5)
      submit(concept: "n_plus_one", date: Date.current - 2)

      expect(user.concept_exposure_count("n_plus_one", "ruby_rails", on_or_before: Date.current - 5)).to eq(1)
      expect(user.concept_exposure_count("n_plus_one", "ruby_rails", on_or_before: Date.current)).to eq(2)
    end

    it "does not count occurrences from a different language bucket" do
      submit(concept: "closures", date: Date.current - 1, language: "javascript")
      expect(user.concept_exposure_count("closures", "ruby_rails", on_or_before: Date.current)).to eq(0)
      expect(user.concept_exposure_count("closures", "javascript", on_or_before: Date.current)).to eq(1)
    end

    it "counts a concept tagged on two sections of the same day as one exposure" do
      date = Date.current
      exercise = user.daily_exercises.create!(date: date, generated_at: Time.current, language: "ruby_rails",
        problem_set: {
          "code_review" => { "concept" => "n_plus_one" },
          "pattern"     => { "concept" => "n_plus_one" }
        })
      user.daily_responses.create!(daily_exercise: exercise, date: date, submitted_at: Time.current,
        answers: { "code_review" => "x" * 20, "pattern" => "x" * 20 },
        concept_tags: { "code_review" => "n_plus_one", "pattern" => "n_plus_one" })

      expect(user.concept_exposure_count("n_plus_one", "ruby_rails", on_or_before: date)).to eq(1)
    end

    it "counts a submitted response's skipped section as an exposure" do
      date = Date.current
      exercise = user.daily_exercises.create!(date: date, generated_at: Time.current, language: "ruby_rails",
        problem_set: { "code_review" => { "concept" => "n_plus_one" } })
      user.daily_responses.create!(daily_exercise: exercise, date: date, submitted_at: Time.current,
        answers: { "code_review" => "" }, concept_tags: { "code_review" => "n_plus_one" })

      expect(user.concept_exposure_count("n_plus_one", "ruby_rails", on_or_before: date)).to eq(1)
    end
  end

  describe "exposure index query budget" do
    def count_queries
      count = 0
      sub = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
        count += 1 unless payload[:name].to_s =~ /SCHEMA|TRANSACTION/ || payload[:sql] =~ /^\s*(BEGIN|COMMIT|ROLLBACK)/
      end
      yield
      count
    ensure
      ActiveSupport::Notifications.unsubscribe(sub)
    end

    it "renders improved_code visibility for many responses with a single index query shared through inverse_of" do
      user = User.create!(email: "budget@example.com", name: "B")
      3.times do |i|
        ex = user.daily_exercises.create!(date: Date.current - i, generated_at: Time.current, language: "ruby_rails",
          problem_set: { "code_review" => { "concept" => "n_plus_one" } })
        user.daily_responses.create!(daily_exercise: ex, date: Date.current - i, submitted_at: Time.current,
          answers: { "code_review" => "x" * 20 }, concept_tags: { "code_review" => "n_plus_one" })
      end

      reloaded  = User.find(user.id)
      responses = reloaded.daily_responses.includes(:daily_exercise).to_a

      queries = count_queries { responses.each { |r| r.improved_code_visible?("code_review") } }
      expect(queries).to eq(1)
    end
  end

  describe "#current_streak" do
    include ActiveSupport::Testing::TimeHelpers

    let(:user) { create_user }

    let(:wednesday) { Time.utc(2026, 7, 22, 12) }

    def exercise_on(date)
      user.daily_exercises.create!(date: date, generated_at: Time.current,
                                   problem_set: { "code_review" => { "question" => "q" } })
    end

    def submit_on(date)
      user.daily_responses.create!(daily_exercise: exercise_on(date), date: date,
                                   submitted_at: Time.current, answers: {})
    end

    it "is 0 with no submissions" do
      travel_to(wednesday) { expect(user.current_streak).to eq(0) }
    end

    it "counts consecutive submitted weekdays ending today" do
      travel_to(wednesday) do
        submit_on(Date.current)
        submit_on(Date.current - 1)
        submit_on(Date.current - 2)
        expect(user.current_streak).to eq(3)
      end
    end

    it "bridges weekends: Friday to Monday is continuous" do
      travel_to(wednesday) do
        submit_on(Date.current)
        submit_on(Date.current - 1)
        submit_on(Date.current - 2)
        submit_on(Date.current - 5)
        expect(user.current_streak).to eq(4)
      end
    end

    it "resets at a weekday whose exercise went unsubmitted" do
      travel_to(wednesday) do
        submit_on(Date.current)
        exercise_on(Date.current - 1)
        submit_on(Date.current - 2)
        expect(user.current_streak).to eq(1)
      end
    end

    it "does not break on today while it is still unsubmitted" do
      travel_to(wednesday) do
        exercise_on(Date.current)
        submit_on(Date.current - 1)
        submit_on(Date.current - 2)
        expect(user.current_streak).to eq(2)
      end
    end

    it "skips a weekday where no exercise existed at all" do
      travel_to(wednesday) do
        submit_on(Date.current)
        submit_on(Date.current - 2)
        expect(user.current_streak).to eq(2)
      end
    end

    it "gives no credit for weekend submissions (streak counts weekdays only)" do
      travel_to(wednesday) do
        submit_on(Date.current - 3)
        expect(user.current_streak).to eq(0)
      end
    end

    it "computes 'today' in the caller's zone" do
      # 02:30 UTC Wednesday is Tuesday evening in Los Angeles, so the streak ends on local Tuesday.
      travel_to(Time.utc(2026, 7, 22, 2, 30)) do
        Time.use_zone("America/Los_Angeles") do
          submit_on(Date.current)
          submit_on(Date.current - 1)
          expect(user.current_streak).to eq(2)
        end
      end
    end
  end

  describe "#daily_section_count" do
    let(:user) { User.create!(email: "sections@example.com", name: "Sections") }

    it "defaults to Automatic" do
      expect(user.daily_section_count).to be_nil
    end

    it "accepts every count a day can hold" do
      (SectionCount::FLOOR..ExerciseSection::MAX_SECTIONS).each do |count|
        expect(user.update(daily_section_count: count)).to be(true)
      end
    end

    it "derives its choices from the floor and the largest day" do
      expect(User::DAILY_SECTION_COUNTS).to eq(SectionCount::FLOOR..ExerciseSection::MAX_SECTIONS)
    end

    it "refuses a count below the floor or above the largest day" do
      [ SectionCount::FLOOR - 1, ExerciseSection::MAX_SECTIONS + 1 ].each do |count|
        user.daily_section_count = count

        expect(user).not_to be_valid
        expect(user.errors[:daily_section_count]).to be_present
      end
    end

    it "refuses a value that would cast to a count or to Automatic" do
      [ "2.5", "abc" ].each do |raw|
        user.daily_section_count = raw

        expect(user).not_to be_valid
      end
    end

    it "does not block an unrelated save when a stored count falls outside today's range" do
      user.update_column(:daily_section_count, ExerciseSection::MAX_SECTIONS + 1)

      expect(user.reload.update(name: "Renamed")).to be(true)
    end

    it "never offers fewer sections than the fixed kinds every day holds" do
      expect(SectionCount::FLOOR).to be >= ExerciseSection.fixed.size
    end

    it "no longer reads the retired adaptive_set_size column" do
      expect(User.column_names).not_to include("adaptive_set_size")
    end
  end

  describe "reminder level" do
    let(:user) do
      User.create!(email: "level@example.com", name: "Level", provider: "anthropic", api_keys: { "anthropic" => "sk-ant-test" })
    end

    it "defaults to none, so a new account is not enrolled" do
      expect(user.reminders_none?).to be(true)
      expect(user.push_reminders_enabled?).to be(false)
    end

    it "treats every non-none level as enrolled, since that predicate answers transport" do
      user.update!(reminder_level: :ready)
      expect(user.push_reminders_enabled?).to be(true)

      user.update!(reminder_level: :ready_and_nudges)
      expect(user.push_reminders_enabled?).to be(true)
    end

    it "drops to none when the account is anonymized" do
      user.update!(reminder_level: :ready_and_nudges)
      user.anonymize!
      expect(user.reload.reminders_none?).to be(true)
    end
  end

  describe "section kind preferences" do
    it "starts with no stated preference at all" do
      user = create_user_with_key

      expect(user.section_kind_weights).to eq({})
      expect(user.excluded_section_kinds).to eq([])
    end

    it "accepts a stated stop for a rotatable kind" do
      user = create_user_with_key
      user.section_kind_weights = { "challenge" => 0.25 }

      expect(user).to be_valid
    end

    it "rejects a weight for a kind that does not compete for a slot" do
      user = create_user_with_key
      user.section_kind_weights = { "code_review" => 0.5 }

      expect(user).not_to be_valid
      expect(user.errors[:section_kind_weights]).to be_present
    end

    it "rejects a weight that is not one of the stops" do
      user = create_user_with_key
      user.section_kind_weights = { "challenge" => 3.0 }

      expect(user).not_to be_valid
      expect(user.errors[:section_kind_weights]).to be_present
    end

    it "rejects an exclusion naming an unknown kind" do
      user = create_user_with_key
      user.excluded_section_kinds = [ "nonsense" ]

      expect(user).not_to be_valid
      expect(user.errors[:excluded_section_kinds]).to be_present
    end

    it "allows excluding all but one kind in a slot" do
      user = create_user_with_key
      user.excluded_section_kinds = ExerciseSection.thirds.drop(1).map(&:key)

      expect(user).to be_valid
    end

    it "still saves unrelated attributes when a stored kind has left the registry, so login keeps working" do
      user = create_user_with_key
      user.update!(excluded_section_kinds: [ "parsons_problem" ])

      allow(ExerciseSection).to receive(:rotatable)
        .and_return(ExerciseSection.rotatable - [ ExerciseSection::ParsonsProblem ])

      expect { user.generate_login_code! }.not_to raise_error
    end

    it "still validates a kind the user is actively changing" do
      user = create_user_with_key

      allow(ExerciseSection).to receive(:rotatable)
        .and_return(ExerciseSection.rotatable - [ ExerciseSection::ParsonsProblem ])
      user.excluded_section_kinds = [ "parsons_problem" ]

      expect(user).not_to be_valid
    end

    it "refuses an exclusion that would empty a slot" do
      user = create_user_with_key
      user.excluded_section_kinds = ExerciseSection.thirds.map(&:key)

      expect(user).not_to be_valid
      expect(user.errors[:excluded_section_kinds].join).to include("third")
    end

    it "refuses an exclusion that would empty the fourth slot" do
      user = create_user_with_key
      user.excluded_section_kinds = ExerciseSection.fourths.map(&:key)

      expect(user).not_to be_valid
      expect(user.errors[:excluded_section_kinds].join).to include("fourth")
    end

    describe "difficulty targets" do
      it "starts with no stated target or lock" do
        user = create_user_with_key

        expect(user.section_kind_levels).to eq({})
        expect(user.locked_section_kinds).to eq([])
      end

      it "accepts a level for a kind that does not rotate" do
        user = create_user_with_key
        user.section_kind_levels = { "code_review" => "principal_engineer" }

        expect(user).to be_valid
      end

      it "rejects a level for an unknown kind" do
        user = create_user_with_key
        user.section_kind_levels = { "nonsense" => "senior" }

        expect(user).not_to be_valid
        expect(user.errors[:section_kind_levels]).to be_present
      end

      it "rejects a level outside the vocabulary" do
        user = create_user_with_key
        user.section_kind_levels = { "challenge" => "strong" }

        expect(user).not_to be_valid
        expect(user.errors[:section_kind_levels]).to be_present
      end

      it "rejects a lock naming an unknown kind" do
        user = create_user_with_key
        user.section_kind_levels = { "challenge" => "senior" }
        user.locked_section_kinds = [ "nonsense" ]

        expect(user).not_to be_valid
        expect(user.errors[:locked_section_kinds]).to be_present
      end

      it "rejects a lock with no level" do
        user = create_user_with_key
        user.locked_section_kinds = [ "challenge" ]

        expect(user).not_to be_valid
        expect(user.errors[:locked_section_kinds].join).to include("challenge")
      end

      it "rejects clearing a level that a lock still depends on" do
        user = create_user_with_key
        user.update!(section_kind_levels: { "challenge" => "senior" }, locked_section_kinds: [ "challenge" ])

        user.section_kind_levels = {}

        expect(user).not_to be_valid
        expect(user.errors[:locked_section_kinds]).to be_present
      end

      it "bumps the preferences version when a level or lock changes" do
        user = create_user_with_key

        expect { user.update!(section_kind_levels: { "pattern" => "junior" }) }
          .to change { user.reload.section_kind_preferences_version }.by(1)
        expect { user.update!(locked_section_kinds: [ "pattern" ]) }
          .to change { user.reload.section_kind_preferences_version }.by(1)
      end

      it "still saves unrelated attributes when a stored level names a retired kind" do
        user = create_user_with_key
        user.update_columns(section_kind_levels: { "retired_kind" => "senior" })

        expect { user.generate_login_code! }.not_to raise_error
      end
    end
  end
end

RSpec.describe User, "#concepts_needing_reinforcement with drills", type: :model do
  let(:user) { User.create!(email: "drill-reinf@example.com", name: "Drill") }

  def submit_response(concept:, section: "code_review", self_rating: "too_hard", ai_rating: "developing", date:)
    exercise = user.daily_exercises.create!(date: date, generated_at: Time.current, language: "ruby_rails",
      problem_set: { section => { "concept" => concept } })
    user.daily_responses.create!(daily_exercise: exercise, date: date, submitted_at: Time.current,
      answers: { section => "x" * 20 }, section_ratings: { section => self_rating },
      concept_tags: { section => concept }, ai_review: { section => { "rating" => ai_rating } })
  end

  it "leads with drilled concepts, flagged, ahead of history-derived entries" do
    submit_response(concept: "n_plus_one", date: Date.current)
    ConceptDrills.start!(user, concept: "memoization", bucket: "ruby_rails")

    expect(user.concepts_needing_reinforcement).to eq([
      { concept: "memoization", bucket: "ruby_rails", tier: "standard", drilled: true },
      { concept: "n_plus_one", bucket: "ruby_rails", tier: "standard" }
    ])
  end

  it "lists a concept that is both drilled and in history once, in the drilled position with its tier" do
    submit_response(concept: "n_plus_one", date: Date.current)
    submit_response(concept: "memoization", date: Date.current - 1)
    ConceptDrills.start!(user, concept: "memoization", bucket: "ruby_rails")
    user.concept_masteries.find_by(concept: "memoization").update!(tier: :reduced)

    result = user.concepts_needing_reinforcement
    expect(result.first).to eq(concept: "memoization", bucket: "ruby_rails", tier: "reduced", drilled: true)
    expect(result.count { |h| h[:concept] == "memoization" }).to eq(1)
  end

  it "orders drilled concepts never-seen first, then least recently seen" do
    submit_response(concept: "n_plus_one", date: Date.current - 1)
    submit_response(concept: "memoization", date: Date.current - 5)
    ConceptDrills.start!(user, concept: "n_plus_one", bucket: "ruby_rails")
    ConceptDrills.start_group!(user, group: "module_design", bucket: "ruby_rails")
    user.concept_masteries.create!(concept: "memoization", language: "ruby_rails", drilled_at: Time.current)

    drilled = user.concepts_needing_reinforcement.select { |h| h[:drilled] }.map { |h| h[:concept] }
    expect(drilled.last(2)).to eq(%w[memoization n_plus_one])
    expect(drilled.first(3)).to match_array(AiService::MODULE_DESIGN_CONCEPTS)
  end

  it "holds a drilled concept back while it is paused" do
    ConceptDrills.start!(user, concept: "n_plus_one", bucket: "ruby_rails")
    user.concept_masteries.find_by(concept: "n_plus_one").update!(tier: :paused, cooldown_remaining: 2)

    expect(user.concepts_needing_reinforcement).to eq([])
  end

  it "with hostable:, offers only drills the caller says today can host" do
    ConceptDrills.start!(user, concept: "sync_vs_async", bucket: "architecture")
    ConceptDrills.start!(user, concept: "n_plus_one", bucket: "ruby_rails")

    only_rails = ->(_concept, bucket) { bucket == "ruby_rails" }
    expect(user.concepts_needing_reinforcement(hostable: only_rails).map { |h| h[:concept] }).to eq(%w[n_plus_one])
    expect(user.concepts_needing_reinforcement(hostable: ->(*) { true }).map { |h| h[:concept] })
      .to match_array(%w[n_plus_one sync_vs_async])
  end

  it "applies the bucket filters to drilled concepts" do
    ConceptDrills.start!(user, concept: "scope_creep", bucket: "plan_review")
    ConceptDrills.start!(user, concept: "n_plus_one", bucket: "ruby_rails")

    expect(user.concepts_needing_reinforcement(bucket: "plan_review").map { |h| h[:concept] }).to eq(%w[scope_creep])
    expect(user.concepts_needing_reinforcement(exclude_buckets: %w[plan_review]).map { |h| h[:concept] }).to eq(%w[n_plus_one])
  end
end

RSpec.describe User, "#concepts_needing_reinforcement across language buckets", type: :model do
  let(:user) { User.create!(email: "mixed-reinf@example.com", name: "Mixed", language: "mixed") }

  def submit_response(concept:, language:, date:, self_rating: "too_hard", ai_rating: "developing")
    exercise = user.daily_exercises.create!(date: date, generated_at: Time.current, language: language,
      problem_set: { "code_review" => { "concept" => concept } })
    user.daily_responses.create!(daily_exercise: exercise, date: date, submitted_at: Time.current,
      answers: { "code_review" => "x" * 20 }, section_ratings: { "code_review" => self_rating },
      concept_tags: { "code_review" => concept }, ai_review: { "code_review" => { "rating" => ai_rating } })
  end

  it "carries each entry's bucket and keeps a same-named concept from both languages" do
    submit_response(concept: "over_mocking", language: "javascript", date: Date.current)
    submit_response(concept: "over_mocking", language: "ruby_rails", date: Date.current - 1)

    expect(user.concepts_needing_reinforcement).to eq([
      { concept: "over_mocking", bucket: "javascript", tier: "standard" },
      { concept: "over_mocking", bucket: "ruby_rails", tier: "standard" }
    ])
  end

  it "resolves mastery per bucket, so a mastered javascript occurrence does not hide a struggling ruby one" do
    submit_response(concept: "over_mocking", language: "javascript", date: Date.current,
                    self_rating: "right_level", ai_rating: "strong")
    submit_response(concept: "over_mocking", language: "ruby_rails", date: Date.current - 1)

    expect(user.concepts_needing_reinforcement).to eq([ { concept: "over_mocking", bucket: "ruby_rails", tier: "standard" } ])
  end
end

RSpec.describe User, "#recent_performance without feedback", type: :model do
  it "carries no feedback key, so nothing free-form reaches the generation prompt" do
    user = User.create!(email: "no-feedback@example.com", name: "NF")
    exercise = user.daily_exercises.create!(date: Date.current, generated_at: Time.current, language: "ruby_rails",
                                            problem_set: { "code_review" => { "concept" => "n_plus_one" } })
    user.daily_responses.create!(daily_exercise: exercise, date: Date.current, submitted_at: Time.current,
                                 answers: { "code_review" => "x" * 20 }, concept_tags: { "code_review" => "n_plus_one" })

    expect(user.recent_performance.first).not_to have_key(:feedback)
    expect(DailyResponse.column_names).not_to include("feedback_text")
  end
end

RSpec.describe User, "#carry_held_set_forward!", type: :model do
  include ActiveSupport::Testing::TimeHelpers

  let(:wednesday) { Time.utc(2026, 7, 22, 12) }
  let(:user) { User.create!(email: "holder@example.com", name: "Holder", time_zone: "UTC") }

  def pause_on(date)
    user.update!(paused_generation_at: date.in_time_zone(user.effective_time_zone) + 9.hours)
  end

  def exercise_on(date)
    user.daily_exercises.create!(date: date, generated_at: Time.current,
                                 problem_set: { "code_review" => { "question" => "q" } })
  end

  it "re-dates the unfinished set and its draft to today while the pause stays in place" do
    travel_to(wednesday) do
      held = exercise_on(Date.current - 1)
      draft = user.daily_responses.create!(daily_exercise: held, date: Date.current - 1,
                                           answers: { "code_review" => "a partial answer here" })
      pause_on(Date.current - 1)

      expect(user.carry_held_set_forward!).to eq(held)
      expect(held.reload.date).to eq(Date.current)
      expect(draft.reload.date).to eq(Date.current)
      expect(user.reload.paused_generation_at).to be_present
    end
  end

  it "moves the plan notes with the set, so the coverage cap and the dashboard lines follow it" do
    travel_to(wednesday) do
      held = exercise_on(Date.current - 1)
      held.update!(plan_notes: { "coverage" => "plan_review", "shared_concept" => "feature_envy" })
      pause_on(Date.current - 1)

      user.carry_held_set_forward!

      expect(user.daily_exercises.for_date.first.plan_notes)
        .to eq("coverage" => "plan_review", "shared_concept" => "feature_envy")
    end
  end

  it "does nothing for a user who is not paused" do
    travel_to(wednesday) do
      held = exercise_on(Date.current - 1)

      expect(user.carry_held_set_forward!).to be_nil
      expect(held.reload.date).to eq(Date.current - 1)
    end
  end

  it "leaves a submitted set where it is, so nothing new is offered while paused" do
    travel_to(wednesday) do
      done = exercise_on(Date.current - 1)
      user.daily_responses.create!(daily_exercise: done, date: Date.current - 1, submitted_at: Time.current, answers: {})
      pause_on(Date.current - 1)

      expect(user.carry_held_set_forward!).to be_nil
      expect(done.reload.date).to eq(Date.current - 1)
    end
  end

  it "leaves a set alone whose response was submitted after it was read as held" do
    travel_to(wednesday) do
      held = exercise_on(Date.current - 1)
      response = user.daily_responses.create!(daily_exercise: held, date: Date.current - 1,
                                              answers: { "code_review" => "a" * 20 }, submitted_at: Time.current)
      pause_on(Date.current - 1)
      allow(user).to receive(:held_exercise).and_return(held)

      expect(user.carry_held_set_forward!).to be_nil
      expect(held.reload.date).to eq(Date.current - 1)
      expect(response.reload.date).to eq(Date.current - 1)
    end
  end

  it "writes the exercise before its response" do
    travel_to(wednesday) do
      held = exercise_on(Date.current - 1)
      user.daily_responses.create!(daily_exercise: held, date: Date.current - 1, answers: { "code_review" => "draft" })
      pause_on(Date.current - 1)

      updates = []
      subscription = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
        sql = payload[:sql]
        updates << "daily_exercises" if sql.start_with?("UPDATE \"daily_exercises\"")
        updates << "daily_responses" if sql.start_with?("UPDATE \"daily_responses\"")
      end
      user.carry_held_set_forward!
      ActiveSupport::Notifications.unsubscribe(subscription)

      expect(updates.first(2)).to eq(%w[daily_exercises daily_responses])
    end
  end

  it "leaves a held set that fails validation in place instead of raising" do
    travel_to(wednesday) do
      held = exercise_on(Date.current - 1)
      held.update_columns(language: "klingon")
      pause_on(Date.current - 1)

      expect { expect(user.carry_held_set_forward!).to be_nil }.not_to raise_error
      expect(held.reload.date).to eq(Date.current - 1)
    end
  end

  it "never moves a set over one already dated today" do
    travel_to(wednesday) do
      held = exercise_on(Date.current - 1)
      today = exercise_on(Date.current)
      pause_on(Date.current - 1)

      expect(user.carry_held_set_forward!).to be_nil
      expect(held.reload.date).to eq(Date.current - 1)
      expect(today.reload.date).to eq(Date.current)
    end
  end
end

RSpec.describe User, "#recent_exercise_history with dropped sections", type: :model do
  it "counts a dropped section as scheduled for rotation and carries its count" do
    user = User.create!(email: "drops@example.com", name: "D")
    user.daily_exercises.create!(date: Date.current - 1, generated_at: Time.current, language: "ruby_rails",
      problem_set: { "code_review" => { "question" => "q" }, "pattern" => { "question" => "q" } },
      dropped_sections: [ "challenge" ])

    entry = user.recent_exercise_history(limit: 5).first

    expect(entry.section_keys).to match_array(%w[code_review pattern challenge])
    expect(entry.delivered_section_keys).to match_array(%w[code_review pattern])
    expect(entry.dropped).to eq(1)
  end
end

RSpec.describe User, "trials", type: :model do
  it "is ready with its own key or an active trial, and nothing else" do
    bare = User.create!(email: "bare@example.com", name: "Bare")
    expect(bare).not_to be_provider_ready
    expect(create_user_with_key).to be_provider_ready

    trial = create_trial_user(provider: "fake")
    expect(trial).to be_provider_ready
    expect(trial).to be_trial
    travel_to(trial.trial_ends_at + 1.second) do
      expect(trial).not_to be_provider_ready
      expect(trial).to be_trial_ended
    end
  end

  it "reads a trial account that stored a key of its own as an own-key account, ended or not" do
    trial = create_trial_user(provider: "fake")
    expect(trial).to be_on_trial
    expect(trial).to be_trial_active(now: trial.trial_ends_at - 1.second)
    expect(trial).not_to be_trial_active(now: trial.trial_ends_at)

    trial.update!(provider: "anthropic", api_keys: { "anthropic" => "sk-ant-own" })
    expect(trial).not_to be_on_trial
    expect(trial).not_to be_trial_ended
    expect(trial).to be_provider_ready
    travel_to(trial.trial_ends_at + 1.second) do
      expect(trial).to be_trial
      expect(trial).not_to be_trial_ended
      expect(trial).to be_provider_ready
    end
  end

  it "ends the trial when the account is deleted" do
    trial = create_trial_user(provider: "fake")
    trial.anonymize!

    expect(trial.reload).not_to be_trial_active
    expect(trial).not_to be_provider_ready
    expect { AiService.for(trial) }.to raise_error(AiService::TrialEndedError)
  end

  it "ends the trial at the end of its last day in the user's zone, on the chosen provider" do
    invite, = mint_trial_code(days: 3)
    stub_env("HOUSE_FAKE_API_KEY" => "fake-house-key")
    user = User.create!(email: "z@example.com", name: "Z", time_zone: "Asia/Tokyo")

    expect(user.start_trial!(invite: invite, provider: "fake", consented_at: Time.utc(2026, 10, 6, 14),
                             now: Time.utc(2026, 10, 6, 14))).to be(true)

    expect(user.provider).to eq("fake")
    expect(user.trial_started_at).to eq(Time.utc(2026, 10, 6, 14))
    expect(user.trial_ends_at.in_time_zone("Asia/Tokyo").strftime("%F %T")).to eq("2026-10-08 23:59:59")
  end

  it "counts the trial from when the seat is taken after Tokyo midnight, keeping consent before it as its own time" do
    invite, = mint_trial_code(days: 3)
    stub_env("HOUSE_FAKE_API_KEY" => "fake-house-key")
    user = User.create!(email: "z@example.com", name: "Z", time_zone: "Asia/Tokyo")
    consented = Time.utc(2026, 10, 6, 14, 55)
    redeemed  = Time.utc(2026, 10, 6, 15, 5)

    expect(user.start_trial!(invite: invite, provider: "fake", consented_at: consented, now: redeemed)).to be(true)

    expect(user).to have_attributes(trial_consented_at: consented, trial_started_at: redeemed)
    expect(user.trial_ends_at.in_time_zone("Asia/Tokyo").strftime("%F %T")).to eq("2026-10-09 23:59:59")
  end

  it "refuses a trial on a provider with no house key, a missing code, or a second trial, taking no seat" do
    invite, = mint_trial_code(seats: 3)
    user = User.create!(email: "z@example.com", name: "Z")

    expect(user.start_trial!(invite: invite, provider: "openai", consented_at: Time.current)).to be(false)
    expect(user.start_trial!(invite: nil, provider: "fake", consented_at: Time.current)).to be(false)
    expect(invite.reload.redeemed_count).to eq(0)

    stub_env("HOUSE_FAKE_API_KEY" => "fake-house-key")
    expect(user.start_trial!(invite: invite, provider: "fake", consented_at: Time.current)).to be(true)
    expect(user.start_trial!(invite: invite, provider: "fake", consented_at: Time.current)).to be(false)
    expect(invite.reload.redeemed_count).to eq(1)
  end

  it "keeps a provider with no stored key valid for a trial account" do
    trial = create_trial_user(provider: "fake")
    expect(trial.api_keys).to be_nil
    expect(trial).to be_valid
  end
end
