require "rails_helper"

RSpec.describe RealSource do
  # The drift guard. A method renamed or a migration deleted fails here, in
  # CI, before it can start being skipped at generation time — and the size
  # bound is what keeps "a focused method or small chunk" a rule rather than a
  # hope.
  describe "every curated entry" do
    it "resolves against the deployed source" do
      RealSource.all.each do |excerpt|
        expect(excerpt).to be_resolvable, "#{excerpt.id} no longer resolves"
      end
    end

    it "sits inside the line bounds" do
      RealSource.all.each do |excerpt|
        expect(excerpt.lines).to be_between(RealSource::MIN_LINES, RealSource::MAX_LINES),
                                 "#{excerpt.id} is #{excerpt.lines} lines"
      end
    end

    it "has a unique id" do
      ids = RealSource.all.map(&:id)
      expect(ids.uniq.size).to eq(ids.size)
    end

    it "is one of the two excerpt kinds" do
      expect(RealSource::APPLICATION_CODE).to all(be_a(RealSource::Method))
      expect(RealSource::SCHEMA_REVIEW).to all(be_a(RealSource::Migration))
    end
  end

  describe RealSource::Method do
    let(:excerpt) { described_class.new("app/services/weighted_roll.rb", "pick") }

    it "slices exactly the named def, nothing around it" do
      text = excerpt.text

      expect(text).to start_with("  def self.pick(weights)")
      expect(text).to end_with("  end\n")
      expect(text).not_to include("class WeightedRoll")
    end

    it "does not resolve a method that is not there" do
      expect(described_class.new("app/services/weighted_roll.rb", "not_a_method")).not_to be_resolvable
    end

    it "does not resolve a file that is not there" do
      expect(described_class.new("app/services/nope.rb", "pick")).not_to be_resolvable
    end

    it "keys its id on the method as well as the file" do
      expect(excerpt.id).to eq("app/services/weighted_roll.rb#pick")
    end

    it "says the copy is altered, so the exercise cannot read as a bug report" do
      expect(excerpt.scenario).to include("altered for this exercise")
      expect(excerpt.scenario).to include("The deployed method is fine")
      expect(excerpt.scenario).to include("`app/services/weighted_roll.rb`, `#pick`")
    end

    it "instructs exactly one flaw in a modified copy, never unchanged, never a fictional domain" do
      instruction = excerpt.instruction

      expect(instruction).to include("MODIFIED COPY")
      expect(instruction).to include("EXACTLY ONE flaw")
      expect(instruction).to include("Never return it unchanged")
      expect(instruction).to include("never introduce a second flaw")
      expect(instruction).to include("do not rewrite it into a fictional domain")
      expect(instruction).to include(%(The scenario field must be exactly: "#{excerpt.scenario}"))
      expect(instruction).to include("```ruby\ndef self.pick(weights)")
    end
  end

  describe RealSource::Migration do
    let(:excerpt) { described_class.new("db/migrate/20260905120000_create_push_subscriptions.rb") }

    it "is the whole file" do
      expect(excerpt.text).to eq(File.read(Rails.root.join(excerpt.path)))
    end

    it "names itself without the timestamp" do
      expect(excerpt.name).to eq("create_push_subscriptions")
    end

    it "says it is modelled on the original, not the original" do
      expect(excerpt.scenario).to include("Modelled on Code Gym's own migration")
      expect(excerpt.scenario).to include("This is not that migration")
    end

    it "hands the migration over as reference and asks for exactly one flaw" do
      instruction = excerpt.instruction

      expect(instruction).to include("MODELLED ON this real one")
      expect(instruction).to include("EXACTLY ONE planted data-modeling flaw")
      expect(instruction).to include("create_table :push_subscriptions")
    end
  end

  describe ".pool" do
    it "is empty for test_file, which is what leaves that mode untouched" do
      expect(RealSource.pool(:test_file)).to be_empty
    end

    it "is empty for an unknown mode rather than raising" do
      expect(RealSource.pool(:nope)).to be_empty
    end
  end

  describe ".pick" do
    let(:pool) { RealSource::APPLICATION_CODE }

    it "takes a never-seen entry ahead of every dated one, in list order" do
      seen_all_but_third = pool.each_with_index.to_h { |excerpt, i| [ excerpt.id, Date.current - i ] }
      seen_all_but_third.delete(pool[2].id)

      expect(RealSource.pick(:application_code, last_seen: seen_all_but_third)).to eq(pool[2])
    end

    it "takes the first in list order when nothing has been seen" do
      expect(RealSource.pick(:application_code, last_seen: {})).to eq(pool.first)
    end

    it "takes the longest-unseen entry once every one has had a turn" do
      last_seen = pool.to_h { |excerpt| [ excerpt.id, Date.current ] }
      last_seen[pool[4].id] = Date.current - 60

      expect(RealSource.pick(:application_code, last_seen: last_seen)).to eq(pool[4])
    end

    it "is nil for a mode with no pool" do
      expect(RealSource.pick(:test_file, last_seen: {})).to be_nil
    end

    it "skips an entry that no longer resolves and says so" do
      stale = RealSource::Method.new("app/services/weighted_roll.rb", "renamed_away")
      stub_const("RealSource::POOLS", { application_code: [ stale, pool.first ] })
      allow(Rails.logger).to receive(:warn)

      expect(RealSource.pick(:application_code, last_seen: {})).to eq(pool.first)
      expect(Rails.logger).to have_received(:warn).with(/renamed_away no longer resolves/)
    end
  end

  describe ".last_seen_for" do
    let(:user) { User.create!(email: "seen@example.com", name: "Seen") }

    def exercise_on(date, source:)
      user.daily_exercises.create!(
        date: date, generated_at: Time.current, language: "ruby_rails",
        problem_set: { "code_review" => { "concept" => "memoization", "source" => source }.compact }
      )
    end

    it "reads each grounded excerpt's latest date back out of the stamped trace" do
      exercise_on(Date.current - 10, source: "a#one")
      exercise_on(Date.current - 3,  source: "a#one")
      exercise_on(Date.current - 7,  source: "b#two")

      expect(RealSource.last_seen_for(user)).to eq("a#one" => Date.current - 3, "b#two" => Date.current - 7)
    end

    it "ignores toy days, which carry no trace" do
      exercise_on(Date.current - 1, source: nil)

      expect(RealSource.last_seen_for(user)).to eq({})
    end

    it "is scoped to the one user" do
      other = User.create!(email: "other@example.com", name: "Other")
      other.daily_exercises.create!(date: Date.current - 1, generated_at: Time.current, language: "ruby_rails",
                                    problem_set: { "code_review" => { "source" => "a#one" } })

      expect(RealSource.last_seen_for(user)).to eq({})
    end
  end
end
