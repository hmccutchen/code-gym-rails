require "rails_helper"

RSpec.describe ConceptExposureIndex do
  let(:user) { User.create!(email: "ex@example.com", name: "Ex") }

  def submit(concept:, date:, language: "ruby_rails", section: "code_review", submitted_at: Time.current)
    exercise = user.daily_exercises.create!(date: date, generated_at: Time.current, language: language,
      problem_set: { section => { "concept" => concept } })
    user.daily_responses.create!(daily_exercise: exercise, date: date, submitted_at: submitted_at,
      answers: { section => "x" * 20 }, concept_tags: { section => concept })
  end

  def index = described_class.for(user)

  describe "#count" do
    it "counts occurrences within the same language bucket, on or before the given date" do
      submit(concept: "n_plus_one", date: Date.current - 5)
      submit(concept: "n_plus_one", date: Date.current - 2)

      expect(index.count("n_plus_one", "ruby_rails", on_or_before: Date.current - 5)).to eq(1)
      expect(index.count("n_plus_one", "ruby_rails", on_or_before: Date.current)).to eq(2)
    end

    it "does not count occurrences from a different language bucket" do
      submit(concept: "closures", date: Date.current - 1, language: "javascript")
      expect(index.count("closures", "ruby_rails", on_or_before: Date.current)).to eq(0)
      expect(index.count("closures", "javascript", on_or_before: Date.current)).to eq(1)
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

      expect(index.count("n_plus_one", "ruby_rails", on_or_before: date)).to eq(1)
    end

    it "counts a submitted response's skipped section as an exposure" do
      date = Date.current
      exercise = user.daily_exercises.create!(date: date, generated_at: Time.current, language: "ruby_rails",
        problem_set: { "code_review" => { "concept" => "n_plus_one" } })
      user.daily_responses.create!(daily_exercise: exercise, date: date, submitted_at: Time.current,
        answers: { "code_review" => "" }, concept_tags: { "code_review" => "n_plus_one" })

      expect(index.count("n_plus_one", "ruby_rails", on_or_before: date)).to eq(1)
    end

    it "ignores unsubmitted responses and blank or other tags" do
      submit(concept: "n_plus_one", date: Date.current - 1, submitted_at: nil)
      submit(concept: "other", date: Date.current - 2)

      expect(index.count("n_plus_one", "ruby_rails", on_or_before: Date.current)).to eq(0)
      expect(index.count("other", "ruby_rails", on_or_before: Date.current)).to eq(0)
    end

    it "records a language-independent kind under its own bucket" do
      submit(concept: "scope_creep", date: Date.current - 1, section: "plan_review", language: "javascript")

      expect(index.count("scope_creep", "plan_review", on_or_before: Date.current)).to eq(1)
      expect(index.count("scope_creep", "javascript", on_or_before: Date.current)).to eq(0)
    end
  end

  describe "#last_seen" do
    it "is the latest exposure date, or nil when the concept was never seen in that bucket" do
      submit(concept: "n_plus_one", date: Date.current - 5)
      submit(concept: "n_plus_one", date: Date.current - 2)

      expect(index.last_seen("n_plus_one", "ruby_rails")).to eq(Date.current - 2)
      expect(index.last_seen("n_plus_one", "javascript")).to be_nil
    end
  end

  describe "User#concept_exposures" do
    it "builds one index per user instance with a single query" do
      submit(concept: "n_plus_one", date: Date.current - 1)
      reloaded = User.find(user.id)

      queries = 0
      counter = ->(*, payload) { queries += 1 unless payload[:name].to_s =~ /SCHEMA|TRANSACTION/ }
      ActiveSupport::Notifications.subscribed(counter, "sql.active_record") do
        2.times { reloaded.concept_exposures.count("n_plus_one", "ruby_rails", on_or_before: Date.current) }
      end

      expect(queries).to eq(1)
      expect(reloaded.concept_exposures).to be(reloaded.concept_exposures)
    end
  end
end
