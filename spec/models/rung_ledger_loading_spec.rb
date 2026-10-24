require "rails_helper"

RSpec.describe RungLedger, ".for" do
  let(:user) { User.create!(email: "ledger-loading@example.com", name: "Ledger", language: "ruby_rails") }
  let(:design_answer) { ExerciseSection::DesignComparison.encode_answer("a", "The first piece keeps the query out of the loop.") }
  let(:parsons_answer) { "#{ExerciseSection::ParsonsProblem::ANSWER_PREFIX}2,0,1" }
  let(:long_answer) { "Preload the association so the loop reads loaded rows." }

  def section(concept, rung: nil, eased: nil, **extra)
    { "concept" => concept, "question" => "Q" * 400, "pitched_at" => rung, "eased" => eased }.merge(extra).compact
  end

  def submit_day(date, problem_set, answers:, self_ratings: {}, ai: {}, language: "ruby_rails", plan_notes: {})
    exercise = DailyExercise.create!(user: user, date: date, language: language, problem_set: problem_set,
                                     plan_notes: plan_notes, generated_at: Time.current)
    user.daily_responses.create!(
      daily_exercise: exercise, date: date, submitted_at: Time.current, answers: answers,
      concept_tags: problem_set.transform_values { |s| s["concept"] },
      section_ratings: answers.keys.index_with { |key| self_ratings.fetch(key, "right_level") },
      ai_review: ai.transform_values { |rating| rating ? { "rating" => rating, "correct" => [ "c" ] } : { "correct" => [ "c" ] } }
    )
  end

  def standings(ledger)
    %w[ruby_rails javascript].flat_map do |bucket|
      ConceptBucket.vocabulary_for(bucket).map { |c| [ bucket, c, ledger.held(c, bucket), ledger.developing_toward(c, bucket) ] }
    end
  end

  def seed_history
    submit_day(Date.new(2026, 3, 2),
               { "code_review" => section("n_plus_one", rung: "senior"),
                 "design_comparison" => section("n_plus_one", rung: "senior"),
                 "parsons_problem" => section("callbacks", rung: "mid_level", blocks: %w[a b c]) },
               answers: { "code_review" => long_answer, "design_comparison" => design_answer, "parsons_problem" => parsons_answer },
               ai: { "code_review" => "strong", "design_comparison" => "solid", "parsons_problem" => "solid" })
    submit_day(Date.new(2026, 3, 3),
               { "code_review" => section("n_plus_one", rung: "principal_engineer"),
                 "design_comparison" => section("callbacks", rung: "senior", eased: true) },
               answers: { "code_review" => long_answer, "design_comparison" => design_answer },
               ai: { "code_review" => "developing", "design_comparison" => "strong" })
    submit_day(Date.new(2026, 3, 4),
               { "code_review" => section("over_mocking", rung: "junior"), "design_comparison" => section("over_mocking") },
               answers: { "code_review" => long_answer, "design_comparison" => design_answer },
               ai: { "code_review" => "solid", "design_comparison" => "solid" }, language: "javascript")
    submit_day(Date.new(2026, 3, 5),
               { "code_review" => section("callbacks", rung: "mid_level"), "pattern" => section("n_plus_one", rung: "senior"),
                 "architecture" => section("callbacks", rung: "junior") },
               answers: { "code_review" => long_answer, "pattern" => "too short", "architecture" => long_answer },
               ai: { "code_review" => "solid", "architecture" => nil },
               plan_notes: { "daily_kinds" => %w[code_review] })
    submit_day(Date.new(2026, 3, 6),
               { "code_review" => section("n_plus_one", rung: "senior"), "design_comparison" => section("callbacks", rung: "senior") },
               answers: { "code_review" => long_answer, "design_comparison" => design_answer },
               self_ratings: { "design_comparison" => "too_hard" }, ai: { "code_review" => "beginner", "design_comparison" => "strong" })
  end

  it "answers every concept exactly as a ledger built from fully loaded responses does" do
    seed_history
    fully_loaded = described_class.new(user.daily_responses.submitted.includes(:daily_exercise).order(date: :desc).to_a)
    ledger = described_class.for(user)

    expect(standings(ledger)).to eq(standings(fully_loaded))
    expect(ledger.held("n_plus_one", "ruby_rails")).to be_nil
    expect(ledger.developing_toward("n_plus_one", "ruby_rails")).to eq("junior")
    expect(ledger.held("callbacks", "ruby_rails")).to eq("mid_level")
    expect(ledger.developing_toward("callbacks", "ruby_rails")).to eq("senior")
    expect(ledger.held("over_mocking", "javascript")).to eq("junior")
  end

  it "reads all history in two queries however many days there are" do
    seed_history
    queries = []
    callback = ->(*, payload) { queries << payload[:sql] unless payload[:name] == "SCHEMA" || payload[:cached] }
    ledger = ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { described_class.for(user) }

    expect(ledger.held("callbacks", "ruby_rails")).to eq("mid_level")
    expect(queries.size).to eq(2)
  end
end
