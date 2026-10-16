# spec/models/daily_exercise_spec.rb
require "rails_helper"

RSpec.describe DailyExercise, type: :model do
  let(:user) { User.create!(email: "exercise-owner@example.com", name: "Owner") }

  it "defaults language to ruby_rails" do
    exercise = DailyExercise.create!(user: user, date: Date.current,
                                     problem_set: { "code_review" => {} }, generated_at: Time.current)
    expect(exercise.language).to eq("ruby_rails")
  end

  it "rejects an unrecognized language" do
    exercise = DailyExercise.new(user: user, date: Date.current,
                                 problem_set: { "code_review" => {} }, generated_at: Time.current,
                                 language: "python")
    expect(exercise).not_to be_valid
    expect(exercise.errors[:language]).to be_present
  end

  it "rejects 'mixed' -- language must be a resolved, generatable language, never the meta-preference" do
    exercise = DailyExercise.new(user: user, date: Date.current,
                                 problem_set: { "code_review" => {} }, generated_at: Time.current,
                                 language: "mixed")
    expect(exercise).not_to be_valid
    expect(exercise.errors[:language]).to be_present
  end

  it "accepts ruby_rails and javascript" do
    expect(DailyExercise.new(user: user, date: Date.current, problem_set: { "code_review" => {} },
                             generated_at: Time.current, language: "ruby_rails")).to be_valid
    expect(DailyExercise.new(user: user, date: Date.current, problem_set: { "code_review" => {} },
                             generated_at: Time.current, language: "javascript")).to be_valid
  end

  describe "#architecture" do
    it "reads the architecture blob with indifferent access, nil when absent" do
      user = User.create!(email: "arch@example.com", name: "Arch")
      with_arch = DailyExercise.new(problem_set: { "architecture" => { "concept" => "service_boundaries" } })
      without    = DailyExercise.new(problem_set: { "challenge" => { "concept" => "n_plus_one" } })

      expect(with_arch.architecture[:concept]).to eq("service_boundaries")
      expect(without.architecture).to be_nil
    end
  end

  describe "#security_review" do
    it "reads the security_review blob with indifferent access, nil when absent" do
      with_sec = DailyExercise.new(problem_set: { "security_review" => { "concept" => "xss_prevention" } })
      without  = DailyExercise.new(problem_set: { "challenge" => { "concept" => "n_plus_one" } })

      expect(with_sec.security_review[:concept]).to eq("xss_prevention")
      expect(without.security_review).to be_nil
    end
  end

  describe "#parsons_problem" do
    it "reads the parsons_problem blob with indifferent access, nil when absent" do
      with_parsons = DailyExercise.new(problem_set: { "parsons_problem" => { "title" => "Sort a list" } })
      without      = DailyExercise.new(problem_set: {})

      expect(with_parsons.parsons_problem[:title]).to eq("Sort a list")
      expect(without.parsons_problem).to be_nil
    end
  end

  describe "#plan_review" do
    it "reads the plan_review blob with indifferent access, nil when absent" do
      with_pr = DailyExercise.new(problem_set: { "plan_review" => { "concept" => "scope_creep" } })
      without = DailyExercise.new(problem_set: { "challenge" => { "concept" => "n_plus_one" } })

      expect(with_pr.plan_review[:concept]).to eq("scope_creep")
      expect(without.plan_review).to be_nil
    end
  end

  describe "#ambiguity_hunt" do
    it "reads the ambiguity_hunt blob with indifferent access, nil when absent" do
      with_ah = DailyExercise.new(problem_set: { "ambiguity_hunt" => { "title" => "Vague ask" } })
      without = DailyExercise.new(problem_set: {})

      expect(with_ah.ambiguity_hunt[:title]).to eq("Vague ask")
      expect(without.ambiguity_hunt).to be_nil
    end
  end

  describe "#active_section_keys" do
    it "returns the four sections a current exercise presents" do
      exercise = DailyExercise.new(problem_set: {
        "code_review" => {}, "pattern" => {}, "architecture" => {}, "plan_review" => {}
      })
      expect(exercise.active_section_keys).to eq(%w[code_review pattern architecture plan_review])
    end

    it "presents both fixed kinds first on a day that holds them" do
      exercise = DailyExercise.new(problem_set: {
        "design_comparison" => {}, "code_review" => {}, "challenge" => {}, "plan_review" => {}
      })
      expect(exercise.active_section_keys).to eq(%w[code_review design_comparison challenge plan_review])
    end

    it "returns three for an exercise generated before the fourth slot existed" do
      exercise = DailyExercise.new(problem_set: { "code_review" => {}, "pattern" => {}, "challenge" => {} })
      expect(exercise.active_section_keys).to eq(%w[code_review pattern challenge])
    end

    # FakeService answers with every kind, and a real provider can return an extra third or fourth.
    it "counts only the precedence-resolved third and fourth when a payload holds several" do
      exercise = DailyExercise.new(problem_set: {
        "code_review"     => {}, "pattern"        => {},
        "architecture"    => {}, "challenge"      => {}, "security_review" => {}, "parsons_problem" => {},
        "plan_review"     => {}, "ambiguity_hunt" => {}
      })
      expect(exercise.active_section_keys).to eq(%w[code_review pattern architecture plan_review])
    end

    it "skips a third or fourth key holding null or a non-Hash value, falling through to the next real one" do
      exercise = DailyExercise.new(problem_set: {
        "code_review" => {}, "pattern" => {}, "architecture" => nil, "security_review" => "not a section",
        "challenge" => {}, "plan_review" => [], "ambiguity_hunt" => {}
      })
      expect(exercise.active_section_keys).to eq(%w[code_review pattern challenge ambiguity_hunt])
    end

    it "resolves parsons_problem when it is the only third-shaped key present" do
      exercise = DailyExercise.new(problem_set: { "code_review" => {}, "pattern" => {}, "parsons_problem" => {} })
      expect(exercise.active_section_keys).to eq(%w[code_review pattern parsons_problem])
    end

    it "drops a fixed key holding a non-Hash value" do
      exercise = DailyExercise.new(problem_set: { "code_review" => "junk", "pattern" => {}, "challenge" => {} })
      expect(exercise.active_section_keys).to eq(%w[pattern challenge])
    end

    it "reads the same keys ExerciseSection.resolved_keys does for FakeService's every-kind set" do
      exercise = DailyExercise.new(problem_set: FakeService::EXERCISE_PROBLEM_SET)

      expect(exercise.active_section_keys).to eq(ExerciseSection.resolved_keys(FakeService::EXERCISE_PROBLEM_SET))
      expect(exercise.active_section_keys).to eq(%w[code_review design_comparison pattern architecture])
    end
  end

  describe "section presence" do
    it "agrees with active_section_keys about what counts as present" do
      problem_set = {
        "code_review" => { "question" => "q" },
        "pattern"     => "not a section",
        "challenge"   => { "question" => "q" }
      }
      exercise = DailyExercise.new(problem_set: problem_set)

      present = problem_set.keys.select { |key| ExerciseSection.present?(problem_set, key) }

      expect(exercise.active_section_keys).to match_array(present)
    end
  end

  describe "#with_response_locked" do
    let(:user) { User.create!(email: "locked-#{SecureRandom.hex(3)}@example.com", name: "L") }
    let(:exercise) do
      DailyExercise.create!(user: user, date: Date.current, generated_at: Time.current, language: "ruby_rails",
                            problem_set: { "code_review" => { "question" => "q" } })
    end

    it "yields nil when the day has no response" do
      expect { |block| exercise.with_response_locked(&block) }.to yield_with_args(nil)
    end

    it "yields the response as committed, not as a copy loaded earlier" do
      DailyResponse.create!(user: user, daily_exercise: exercise, date: Date.current, answers: {})
      exercise.daily_response
      DailyResponse.where(daily_exercise_id: exercise.id).update_all(submitted_at: Time.current)

      exercise.with_response_locked { |response| expect(response).to be_submitted }
    end

    it "yields nil when the response was deleted after the exercise loaded it" do
      DailyResponse.create!(user: user, daily_exercise: exercise, date: Date.current, answers: {})
      exercise.daily_response
      DailyResponse.where(daily_exercise_id: exercise.id).delete_all

      expect { |block| exercise.with_response_locked(&block) }.to yield_with_args(nil)
    end

    it "locks the exercise before the response" do
      DailyResponse.create!(user: user, daily_exercise: exercise, date: Date.current, answers: {})
      locked_tables = []
      record = ->(*, payload) { locked_tables << payload[:sql][/FROM "(\w+)"/, 1] if payload[:sql].include?("FOR UPDATE") }

      ActiveSupport::Notifications.subscribed(record, "sql.active_record") { exercise.with_response_locked { } }

      expect(locked_tables).to eq(%w[daily_exercises daily_responses])
    end

    it "returns the block's value" do
      expect(exercise.with_response_locked { :done }).to eq(:done)
    end
  end

  describe "#regenerating?" do
    let(:user) { User.create!(email: "regen-model@example.com", name: "Regen") }

    def exercise(regenerating_since: nil)
      DailyExercise.create!(user: user, date: Date.current, generated_at: Time.current,
                            problem_set: { "code_review" => { "question" => "q" } },
                            regenerating_since: regenerating_since)
    end

    it "is false when no regeneration has been claimed" do
      expect(exercise).not_to be_regenerating
    end

    it "is true while a fresh claim is held" do
      expect(exercise(regenerating_since: 10.seconds.ago)).to be_regenerating
    end

    # A dead worker would otherwise strand the user on a spinner forever.
    it "is false once the claim is older than the stale window" do
      stale = DailyExercise::REGENERATION_STALE_AFTER.ago - 1.second
      expect(exercise(regenerating_since: stale)).not_to be_regenerating
    end

    # A shorter claim lets a still-running job look abandoned, so a second one piles on.
    it "outlasts the worker's generation budget" do
      expect(DailyExercise::REGENERATION_STALE_AFTER.to_i).to be > AiService::GENERATION_READ_TIMEOUT
    end

    it "outlasts the draft call's worst case, retries included, plus job pickup" do
      worst_case = AiService.worst_case_call_seconds(AiService::GENERATION_READ_TIMEOUT)

      expect(DailyExercise::REGENERATION_STALE_AFTER.to_i)
        .to be >= worst_case + DailyExercise::JOB_PICKUP_MARGIN.to_i
    end

    it "still holds a claim taken seven minutes ago, past the old six-minute window" do
      held = exercise(regenerating_since: 7.minutes.ago)

      expect(held).to be_regenerating
      expect(held.claim_regenerating!(regenerated_at: nil)).to be_nil
    end
  end
end
