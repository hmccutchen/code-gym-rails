require "rails_helper"

RSpec.describe User, "pausing generation and who paused it" do
  let(:user) { User.create!(email: "pauser@example.com", time_zone: "UTC") }
  let(:wednesday) { Time.utc(2026, 11, 11, 12) }

  def stored = user.reload.slice(:paused_generation_at, :generation_pause_source).symbolize_keys

  it "names the two sources a pause can have" do
    expect(User::GENERATION_PAUSE_SOURCES).to eq(%w[manual automatic])
  end

  describe "#pause_generation!" do
    it "stamps the pause and its source on a running account" do
      travel_to(wednesday) { expect(user.pause_generation!(source: "automatic")).to eq(:paused) }

      expect(stored).to eq(paused_generation_at: wednesday, generation_pause_source: "automatic")
    end

    it "changes an automatic pause to manual without moving the pause time" do
      travel_to(wednesday) { user.pause_generation!(source: "automatic") }

      travel_to(wednesday + 2.days) { expect(user.pause_generation!(source: "manual")).to eq(:kept) }

      expect(stored).to eq(paused_generation_at: wednesday, generation_pause_source: "manual")
    end

    it "leaves a manual pause manual when the hand-out reaches an account that paused itself first" do
      travel_to(wednesday) { user.pause_generation!(source: "manual") }

      travel_to(wednesday + 1.hour) { expect(user.pause_generation!(source: "automatic")).to eq(:kept) }

      expect(stored).to eq(paused_generation_at: wednesday, generation_pause_source: "manual")
    end

    it "decides from the stored row, though this copy was loaded before another request paused it" do
      stale = User.find(user.id)
      travel_to(wednesday) { user.pause_generation!(source: "manual") }

      travel_to(wednesday + 1.hour) { expect(stale.pause_generation!(source: "automatic")).to eq(:kept) }

      expect(stored).to eq(paused_generation_at: wednesday, generation_pause_source: "manual")
    end

    it "refuses a source outside the list and writes nothing" do
      expect { user.pause_generation!(source: "holiday") }.to raise_error(ArgumentError)

      expect(stored).to eq(paused_generation_at: nil, generation_pause_source: nil)
    end
  end

  describe "#clear_generation_pause!" do
    it "clears the pause time and the source in one write" do
      user.pause_generation!(source: "automatic")

      user.clear_generation_pause!

      expect(stored).to eq(paused_generation_at: nil, generation_pause_source: nil)
    end

    it "clears a source left with no pause time" do
      user.update_columns(paused_generation_at: nil, generation_pause_source: "automatic")

      user.clear_generation_pause!

      expect(stored).to eq(paused_generation_at: nil, generation_pause_source: nil)
    end
  end

  describe "acknowledging unopened sets when the pause is cleared" do
    let(:today) { Date.new(2026, 11, 12) }
    let(:resumed_at) { Time.utc(2026, 11, 12, 15) }

    def set_on(date)
      user.daily_exercises.create!(date: date, generated_at: date.in_time_zone("UTC") + 13.hours,
                                   problem_set: { "code_review" => { "question" => "q" } })
    end

    it "stamps the sets that count as unopened with the resume time" do
      sets = [ today - 3, today - 2, today - 1 ].map { |date| set_on(date) }
      travel_to(resumed_at - 2.hours) { user.pause_generation!(source: "automatic") }

      travel_to(resumed_at) { user.resume_generation! }

      expect(sets.map { |set| set.reload.opened_at }).to eq([ resumed_at ] * 3)
    end

    it "reads today in the user's zone, whatever zone the caller is in" do
      user.update!(time_zone: "Pacific/Auckland")
      yesterday_there = set_on(today)
      today_there = set_on(today + 1)
      user.pause_generation!(source: "manual")

      travel_to(resumed_at) { Time.use_zone("UTC") { user.clear_generation_pause! } }

      expect([ yesterday_there, today_there ].map { |set| set.reload.opened_at }).to eq([ resumed_at, nil ])
    end

    it "leaves a held set it carries forward to today unstamped, since nobody has been shown it yet" do
      travel_to(resumed_at - 2.days) { user.pause_generation!(source: "manual") }
      held = set_on(today - 1)

      travel_to(resumed_at) { expect(user.resume_generation!).to eq(held) }

      expect(held.reload).to have_attributes(date: today, opened_at: nil)
    end

    it "keeps the pause and the sets as they were when clearing the pause fails, so neither is written without the other" do
      sets = [ today - 2, today - 1 ].map { |date| set_on(date) }
      travel_to(resumed_at - 1.day) { user.pause_generation!(source: "automatic") }
      allow(user).to receive(:update!).and_raise(ActiveRecord::RecordInvalid.new(user))

      travel_to(resumed_at) { expect { user.clear_generation_pause! }.to raise_error(ActiveRecord::RecordInvalid) }

      expect(sets.map { |set| set.reload.opened_at }).to eq([ nil, nil ])
      expect(stored[:generation_pause_source]).to eq("automatic")
    end

    it "acknowledges nothing on a pause, a repeated pause or Keep it paused" do
      sets = [ today - 3, today - 2, today - 1 ].map { |date| set_on(date) }

      travel_to(resumed_at) do
        user.pause_generation!(source: "automatic")
        user.pause_generation!(source: "manual")
      end

      expect(sets.map { |set| set.reload.opened_at }).to eq([ nil, nil, nil ])
    end
  end

  describe "#pause_for_unopened_sets!" do
    let(:today) { Date.new(2026, 11, 12) }
    let(:morning) { Time.utc(2026, 11, 12, 13) }

    def set_on(date)
      user.daily_exercises.create!(date: date, generated_at: date.in_time_zone("UTC") + 13.hours,
                                   problem_set: { "code_review" => { "question" => "q" } })
    end

    def decide = travel_to(morning) { Time.use_zone("UTC") { user.pause_for_unopened_sets! } }

    it "pauses as automatic when the last three sets went unopened and today has no set" do
      [ today - 3, today - 2, today - 1 ].each { |date| set_on(date) }

      expect(decide).to eq(:paused)
      expect(stored).to eq(paused_generation_at: morning, generation_pause_source: "automatic")
    end

    it "leaves the account running when a set for today appeared after the hand-out read it" do
      [ today - 3, today - 2, today - 1, today ].each { |date| set_on(date) }

      expect(decide).to eq(:running)
      expect(stored).to eq(paused_generation_at: nil, generation_pause_source: nil)
    end

    it "leaves the account running when the run no longer holds, as after a resume in between" do
      sets = [ today - 3, today - 2, today - 1 ].map { |date| set_on(date) }
      sets.last.update_columns(opened_at: morning - 1.minute)

      expect(decide).to eq(:running)
      expect(user.reload.paused_generation_at).to be_nil
    end

    it "keeps a pause the owner made first" do
      [ today - 3, today - 2, today - 1 ].each { |date| set_on(date) }
      travel_to(morning - 1.hour) { user.pause_generation!(source: "manual") }

      expect(decide).to eq(:kept)
      expect(user.reload.generation_pause_kind).to eq("manual")
    end
  end

  describe "#resume_generation!" do
    it "clears the pause time and the source together, through the concern's one clearing method" do
      user.pause_generation!(source: "automatic")
      allow(user).to receive(:clear_generation_pause!).and_call_original

      user.resume_generation!

      expect(user).to have_received(:clear_generation_pause!).once

      expect(stored).to eq(paused_generation_at: nil, generation_pause_source: nil)
    end
  end

  describe "reading the pause, with the pause time as the authority" do
    it "reads an automatic pause as automatic" do
      user.update_columns(paused_generation_at: wednesday, generation_pause_source: "automatic")

      expect(user).to have_attributes(generation_paused_automatically?: true, generation_pause_kind: "automatic")
    end

    it "reads a manual pause as manual" do
      user.update_columns(paused_generation_at: wednesday, generation_pause_source: "manual")

      expect(user).to have_attributes(generation_paused_automatically?: false, generation_pause_kind: "manual")
    end

    it "reads a pause time with no source as a manual pause" do
      user.update_columns(paused_generation_at: wednesday, generation_pause_source: nil)

      expect(user).to have_attributes(paused_generation_at?: true, generation_paused_automatically?: false,
                                      generation_pause_kind: "manual")
    end

    it "reads a pause time with an unknown source as a manual pause" do
      user.update_columns(paused_generation_at: wednesday, generation_pause_source: "holiday")

      expect(user).to have_attributes(generation_paused_automatically?: false, generation_pause_kind: "manual")
    end

    it "ignores a source with no pause time" do
      user.update_columns(paused_generation_at: nil, generation_pause_source: "automatic")

      expect(user).to have_attributes(paused_generation_at?: false, generation_paused_automatically?: false,
                                      generation_pause_kind: nil)
    end
  end

  describe "saving unrelated settings from either odd state" do
    it "saves for an account with a pause time and no source" do
      user.update_columns(paused_generation_at: wednesday, generation_pause_source: nil)

      expect(user.update(language: "javascript")).to be(true)
      expect(stored).to eq(paused_generation_at: wednesday, generation_pause_source: nil)
    end

    it "saves for an account with a source and no pause time" do
      user.update_columns(paused_generation_at: nil, generation_pause_source: "automatic")

      expect(user.update(language: "javascript")).to be(true)
      expect(stored).to eq(paused_generation_at: nil, generation_pause_source: "automatic")
    end
  end

  describe "#held_exercise after an automatic pause" do
    def unopened_set(date)
      user.daily_exercises.create!(date: date, generated_at: date.in_time_zone("UTC") + 13.hours,
                                   problem_set: { "code_review" => { "question" => "q" } })
    end

    it "picks up none of the three unopened sets, which are dated before the pause, so resume carries nothing forward" do
      monday = Date.new(2026, 11, 9)
      sets = [ monday - 3, monday - 2, monday ].map { |date| unopened_set(date) }
      travel_to(Time.utc(2026, 11, 10, 13)) { user.pause_generation!(source: "automatic") }

      travel_to(Time.utc(2026, 11, 12, 9)) do
        Time.use_zone("UTC") { expect(user.held_exercise).to be_nil }
        expect(user.resume_generation!).to be_nil
      end

      expect(sets.map { |set| set.reload.date }).to eq([ monday - 3, monday - 2, monday ])
      expect(user.daily_exercises.for_date(Date.new(2026, 11, 12))).to be_empty
    end
  end
end
