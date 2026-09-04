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

    # concept_tags is persisted provider output, so it keeps the name a section
    # was tagged with even after that concept leaves the vocabulary. Left
    # unfiltered, a renamed concept keeps being reinforced for the whole
    # 10-session window: the model can no longer tag it, and because DailyPlan
    # sizes retention as the day's hostable sections minus the reinforcement
    # entries claiming them, the dead entry suppresses a retention check that
    # could have used the slot.
    it "skips a tagged concept that is no longer in its bucket's vocabulary" do
      user = create_user
      exercise = DailyExercise.create!(user: user, date: Date.current, problem_set: { "code_review" => {} }, generated_at: Time.current)
      DailyResponse.create!(user: user, daily_exercise: exercise, date: Date.current,
                            answers: { "code_review" => "x" * 20 }, section_ratings: { "code_review" => "too_hard" }, legacy_rating: "too_hard",
                            concept_tags: { "code_review" => "retired_concept" })

      expect(user.concepts_needing_reinforcement).to eq([])
    end

    # The membership filter applies to language buckets, unlike bucket:/
    # exclude_buckets:, so it must run before the dedup marker. RAILS_CONCEPTS
    # and JS_CONCEPTS overlap only partially: n_plus_one is Rails-only, so a
    # JavaScript-day tag naming it is exactly the post-rename orphan this
    # filters. Filtering after the dedup marker would let that dead newer
    # occurrence consume the slot and hide the live Rails-day one.
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
      ConceptMastery.record_review!(response, sections: response.concept_tags.keys, apply_session_countdown: true)
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

  describe "#concepts_needing_reinforcement with bucket filters" do
    let(:user) { User.create!(email: "bucket-filter@example.com", name: "Bucket") }

    def submit_response(concept:, section:, language: "ruby_rails", self_rating: "too_hard", ai_rating: "developing")
      # Distinct, strictly-decreasing dates per call — random dates within a small
      # range risked colliding on DailyExercise's date-uniqueness validation
      # (scoped to user_id) when a test submits more than one response.
      @next_response_date ||= Date.current
      @next_response_date -= 1
      exercise = DailyExercise.create!(
        user: user, date: @next_response_date, generated_at: Time.current, language: language,
        problem_set: { section => { "concept" => concept } }
      )
      DailyResponse.create!(
        user: user, daily_exercise: exercise, date: exercise.date, submitted_at: Time.current,
        answers: { section => "an answer" },
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

  describe "#concepts_due_for_retention_check" do
    let(:user) { User.create!(email: "due@example.com", name: "Due") }

    def mastery(concept:, bucket:, due_on:)
      user.concept_masteries.create!(concept: concept, language: bucket, tier: :standard,
                                     mastered_at: 1.month.ago,
                                     retention_interval_days: 7,
                                     next_retention_check_on: due_on)
    end

    it "returns only due concepts in the requested bucket, most overdue first" do
      mastery(concept: "n_plus_one",   bucket: "ruby_rails", due_on: Date.current - 3)
      mastery(concept: "memoization",  bucket: "ruby_rails", due_on: Date.current - 10)
      mastery(concept: "closures",     bucket: "javascript", due_on: Date.current - 5)
      mastery(concept: "indexing",     bucket: "ruby_rails", due_on: Date.current + 4)

      result = user.concepts_due_for_retention_check(bucket: "ruby_rails", limit: 5)
      expect(result.map(&:concept)).to eq(%w[memoization n_plus_one])
    end

    it "excludes concepts with no schedule" do
      user.concept_masteries.create!(concept: "caching", language: "ruby_rails", tier: :standard)
      expect(user.concepts_due_for_retention_check(bucket: "ruby_rails", limit: 5)).to be_empty
    end

    it "honors the limit" do
      mastery(concept: "n_plus_one",  bucket: "ruby_rails", due_on: Date.current - 3)
      mastery(concept: "memoization", bucket: "ruby_rails", due_on: Date.current - 10)
      expect(user.concepts_due_for_retention_check(bucket: "ruby_rails", limit: 1).map(&:concept)).to eq(%w[memoization])
    end

    # The orphan here is the MOST overdue of the two, so it would sort first
    # without the filter — this fails on membership, not on ordering luck.
    it "excludes a concept no longer in the bucket's vocabulary" do
      mastery(concept: "memoization",      bucket: "ruby_rails", due_on: Date.current - 3)
      mastery(concept: "retired_concept",  bucket: "ruby_rails", due_on: Date.current - 30)

      expect(user.concepts_due_for_retention_check(bucket: "ruby_rails", limit: 5).map(&:concept))
        .to eq(%w[memoization])
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

    # Named from the real vocabulary rather than "short_interval"/"long_interval":
    # the query filters by vocabulary membership, so an invented name would pass
    # this test for the wrong reason. The intervals carry the meaning here.
    it "scales the threshold with each concept's own interval, not a flat number" do
      mastery(concept: "memoization", due_on: Date.current - 8, interval: 7)   # 8 > 7: crossed
      mastery(concept: "n_plus_one",  due_on: Date.current - 8, interval: 28)  # 8 < 28: not crossed
      expect(user.concepts_overdue_for_retention_check(bucket: "ruby_rails").map(&:concept)).to eq(%w[memoization])
    end

    it "excludes rows with a null retention_interval_days even when next_retention_check_on is far in the past" do
      user.concept_masteries.create!(concept: "indexing", language: "ruby_rails", tier: :standard,
                                     mastered_at: 1.month.ago,
                                     retention_interval_days: nil,
                                     next_retention_check_on: Date.current - 100)
      expect(user.concepts_overdue_for_retention_check(bucket: "ruby_rails")).to be_empty
    end

    # A concept dropped or renamed out of a vocabulary leaves its mastery row
    # behind, and that row can never resolve: the generator is only ever offered
    # vocabulary concepts, anything else ingest normalizes to "other", and
    # record_review! skips "other". Unfiltered it is therefore permanently
    # overdue, so overdue_retention_check_pending? would return true every day
    # forever and take a reinforcement slot back each time (issue #97).
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

    # A Wednesday, so the pause day and "today" are both weekdays in one week.
    let(:wednesday) { Time.utc(2026, 7, 22, 12) }

    # A UTC user, so `Date.current` and the pause's local date agree without
    # every example having to reason about the offset. The zone resolution
    # itself gets its own example below.
    let(:user) { User.create!(email: "resumer@example.com", name: "Resumer", time_zone: "UTC") }

    # Paused mid-morning on `date` in the user's own zone, the way
    # AccountsController#toggle_generation writes it under use_time_zone.
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

    # regenerated_at means "this row's day has spent its regeneration". Carrying
    # it onto a new day would hide the Generate-new-set button behind a false
    # claim ("You've already generated a new set today").
    # RegenerateExerciseJob gates only on `exercise&.regenerating_since` after
    # resolving for_date, so a claim left over from the pause day would let a
    # stranded retry replace the carried-forward set and destroy its draft.
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

    # `date` uniqueness is enforced twice, and the model validation fires first,
    # so RecordInvalid is the likelier of the two — a rescue for only
    # RecordNotUnique would 500 and roll the pause clearing back with it.
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

    # /generate is not pause-gated, so a paused user can trigger a failing
    # generation while the held set sits at an earlier date — nothing for
    # persist_failure to suppress the report against. Recovering that set makes
    # the error stale, and the dashboard would otherwise render "Couldn't
    # generate a new set" above it.
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

    # Reading the pause day in the user's zone but "today" in the caller's is
    # not merely untidy — the two can name the same date and collapse the
    # search range to empty. Tokyo is far enough ahead of an ambient-UTC caller
    # to show it: at 20:00 UTC on the 22nd it is already the 23rd in Tokyo, so
    # the user's today is the 23rd while the caller's is the 22nd — the same
    # 22nd the pause began on locally.
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

    it "renders improved_code visibility for many responses with a single index query" do
      user = User.create!(email: "budget@example.com", name: "B")
      3.times do |i|
        ex = user.daily_exercises.create!(date: Date.current - i, generated_at: Time.current, language: "ruby_rails",
          problem_set: { "code_review" => { "concept" => "n_plus_one" } })
        user.daily_responses.create!(daily_exercise: ex, date: Date.current - i, submitted_at: Time.current,
          answers: { "code_review" => "x" * 20 }, concept_tags: { "code_review" => "n_plus_one" })
      end

      reloaded  = User.find(user.id)
      responses = reloaded.daily_responses.includes(:daily_exercise).to_a # exercises + user preloaded

      queries = count_queries { responses.each { |r| r.improved_code_visible?("code_review") } }
      expect(queries).to eq(1) # the exposure index, built once and shared (inverse_of)
    end
  end

  describe "#current_streak" do
    include ActiveSupport::Testing::TimeHelpers

    let(:user) { create_user }

    # A Wednesday, so "today" and the two prior weekdays sit inside one week.
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
        submit_on(Date.current)     # Wed
        submit_on(Date.current - 1) # Tue
        submit_on(Date.current - 2) # Mon
        expect(user.current_streak).to eq(3)
      end
    end

    it "bridges weekends: Friday to Monday is continuous" do
      travel_to(wednesday) do
        submit_on(Date.current)     # Wed
        submit_on(Date.current - 1) # Tue
        submit_on(Date.current - 2) # Mon
        submit_on(Date.current - 5) # previous Fri
        expect(user.current_streak).to eq(4)
      end
    end

    it "resets at a weekday whose exercise went unsubmitted" do
      travel_to(wednesday) do
        submit_on(Date.current)          # Wed
        exercise_on(Date.current - 1)    # Tue: exercise existed, never submitted
        submit_on(Date.current - 2)      # Mon
        expect(user.current_streak).to eq(1)
      end
    end

    it "does not break on today while it is still unsubmitted" do
      travel_to(wednesday) do
        exercise_on(Date.current)   # Wed: in progress
        submit_on(Date.current - 1) # Tue
        submit_on(Date.current - 2) # Mon
        expect(user.current_streak).to eq(2)
      end
    end

    it "skips a weekday where no exercise existed at all" do
      travel_to(wednesday) do
        submit_on(Date.current)     # Wed
        submit_on(Date.current - 2) # Mon; Tue has no exercise (generation failed)
        expect(user.current_streak).to eq(2)
      end
    end

    it "gives no credit for weekend submissions (streak counts weekdays only)" do
      travel_to(wednesday) do
        submit_on(Date.current - 3) # Sunday, via the manual weekend generate
        expect(user.current_streak).to eq(0)
      end
    end

    it "computes 'today' in the caller's zone" do
      # 02:30 UTC Wednesday is Tuesday evening in Los Angeles: the local
      # streak ends on local-today (Tue), not the UTC day.
      travel_to(Time.utc(2026, 7, 22, 2, 30)) do
        Time.use_zone("America/Los_Angeles") do
          submit_on(Date.current)     # local Tue
          submit_on(Date.current - 1) # local Mon
          expect(user.current_streak).to eq(2)
        end
      end
    end
  end

  describe "#adaptive_set_size" do
    it "defaults on" do
      user = User.create!(email: "toggle@example.com", name: "Toggle")

      expect(user.adaptive_set_size?).to be(true)
    end
  end
end
