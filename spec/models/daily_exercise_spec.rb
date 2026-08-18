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

  describe "#fourth_key" do
    it "returns 'plan_review' when present" do
      exercise = DailyExercise.new(problem_set: { "plan_review" => {} })
      expect(exercise.fourth_key).to eq("plan_review")
    end

    it "returns 'ambiguity_hunt' when present without plan_review" do
      exercise = DailyExercise.new(problem_set: { "ambiguity_hunt" => {} })
      expect(exercise.fourth_key).to eq("ambiguity_hunt")
    end

    it "returns nil for an old exercise with neither fourth-slot key — no fallback kind" do
      exercise = DailyExercise.new(problem_set: { "code_review" => {}, "pattern" => {}, "challenge" => {} })
      expect(exercise.fourth_key).to be_nil
    end

    it "skips a fourth key holding a non-Hash value, falling through to the next real section" do
      exercise = DailyExercise.new(problem_set: { "plan_review" => "not a section", "ambiguity_hunt" => {} })
      expect(exercise.fourth_key).to eq("ambiguity_hunt")
    end
  end

  describe "#active_section_keys" do
    it "returns the four sections a current exercise presents" do
      exercise = DailyExercise.new(problem_set: {
        "code_review" => {}, "pattern" => {}, "architecture" => {}, "plan_review" => {}
      })
      expect(exercise.active_section_keys).to eq(%w[code_review pattern architecture plan_review])
    end

    it "returns three for an exercise generated before the fourth slot existed" do
      exercise = DailyExercise.new(problem_set: { "code_review" => {}, "pattern" => {}, "challenge" => {} })
      expect(exercise.active_section_keys).to eq(%w[code_review pattern challenge])
    end

    # The count the user sees is the count of sections on screen, not of raw
    # payload keys — FakeService persists all eight deliberately, and a real
    # provider can return an extra alternate third or fourth.
    it "counts only the precedence-resolved third and fourth when a payload holds several" do
      exercise = DailyExercise.new(problem_set: {
        "code_review"     => {}, "pattern"        => {},
        "architecture"    => {}, "challenge"      => {}, "security_review" => {}, "parsons_problem" => {},
        "plan_review"     => {}, "ambiguity_hunt" => {}
      })
      expect(exercise.active_section_keys).to eq(%w[code_review pattern architecture plan_review])
    end

    it "drops a fixed key holding a non-Hash value" do
      exercise = DailyExercise.new(problem_set: { "code_review" => "junk", "pattern" => {}, "challenge" => {} })
      expect(exercise.active_section_keys).to eq(%w[pattern challenge])
    end
  end

  describe "#third_key" do
    it "returns 'architecture' when the architecture key is present" do
      exercise = DailyExercise.new(problem_set: { "architecture" => {} })
      expect(exercise.third_key).to eq("architecture")
    end

    it "returns 'security_review' when present without architecture" do
      exercise = DailyExercise.new(problem_set: { "security_review" => {} })
      expect(exercise.third_key).to eq("security_review")
    end

    it "returns 'challenge' when neither architecture nor security_review is present" do
      exercise = DailyExercise.new(problem_set: { "challenge" => {} })
      expect(exercise.third_key).to eq("challenge")
    end

    it "skips a third key present with a null value, falling through to the next real section" do
      exercise = DailyExercise.new(problem_set: { "architecture" => nil, "challenge" => {} })
      expect(exercise.third_key).to eq("challenge")
    end

    it "skips a third key holding a non-Hash value, falling through to the next real section" do
      exercise = DailyExercise.new(problem_set: { "architecture" => "not a section", "challenge" => {} })
      expect(exercise.third_key).to eq("challenge")
    end

    it "skips a non-Hash architecture in favour of a real security_review" do
      exercise = DailyExercise.new(problem_set: { "architecture" => [], "security_review" => {} })
      expect(exercise.third_key).to eq("security_review")
    end

    it "resolves to parsons_problem when that's the only third-shaped key present" do
      exercise = DailyExercise.new(problem_set: {
        "code_review" => { "concept" => "x" }, "pattern" => { "concept" => "y" },
        "parsons_problem" => { "blocks" => [ "a", "b" ] }
      })
      expect(exercise.third_key).to eq("parsons_problem")
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

    # A worker that dies mid-job would otherwise leave the claim set forever and
    # strand the user on a spinner, so the claim expires rather than latching.
    it "is false once the claim is older than the stale window" do
      stale = DailyExercise::REGENERATION_STALE_AFTER.ago - 1.second
      expect(exercise(regenerating_since: stale)).not_to be_regenerating
    end

    # A claim must outlive the longest generation the worker can legitimately
    # run, or a still-running job looks abandoned and a second one piles on.
    it "outlasts the worker's generation budget" do
      expect(DailyExercise::REGENERATION_STALE_AFTER.to_i).to be > AiService::GENERATION_READ_TIMEOUT
    end
  end
end
