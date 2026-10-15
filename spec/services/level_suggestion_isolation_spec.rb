require "rails_helper"

RSpec.describe "Learning track and level suggestion isolation" do
  around { |example| travel_to(Time.utc(2026, 10, 14, 15)) { example.run } }

  def twin(email, learning_track, cutoffs: {}, suggestions: true)
    User.create!(
      email: email, name: "Twin", time_zone: "UTC", provider: "fake", api_keys: { "fake" => "fake-test-key" },
      language: "ruby_rails", learning_track: learning_track, level_suggestion_cutoffs: cutoffs,
      level_suggestions: suggestions, section_kind_levels: LearningTrack.preset_levels
    )
  end

  def prompts_for(user)
    calls = Queue.new
    random = Random.new(42)
    allow(WeightedRoll).to receive(:rand) { random.rand }
    allow_any_instance_of(Array).to receive(:shuffle).and_wrap_original do |original, **kwargs|
      original.call(**kwargs, random: random)
    end
    allow_any_instance_of(FakeService).to receive(:call).and_wrap_original do |original, **kwargs|
      calls << kwargs.deep_dup
      original.call(**kwargs)
    end

    result = AiService.for(user).generate_judged_exercise(user, language: "ruby_rails")
    captured = Array.new(calls.size) { calls.pop }
    expect(captured.count { |call| call[:purpose] == "generate_exercise" }).to eq(1)
    expect(captured.count { |call| call[:purpose] == "judge_section" }).to eq(result.outcomes.size)
    expect(result.outcomes).not_to be_empty
    expect(result.outcomes.values).to all(include(status: :keep, fallback: nil))

    # Judge threads may finish in any order; the captured values stay untouched.
    captured.sort_by { |call| [ call[:purpose].to_s, call[:prompt].to_s ] }
  end

  def first_difference(expected, actual)
    index = (0...[ expected.size, actual.size ].max).find { |i| expected[i] != actual[i] }
    "First differing provider call at index #{index}:\n" \
      "Expected: #{expected[index].inspect}\nActual: #{actual[index].inspect}"
  end

  it "sends byte-identical generation and judge prompts on and off the track, with suggestions on or off" do
    baseline = prompts_for(twin("legacy@example.com", nil))
    on_track = twin("on@example.com", LearningTrack::ON,
                    cutoffs: { "code_review" => { "level" => "junior", "through" => "2026-10-13" } })
    opted_out = twin("off@example.com", LearningTrack::OFF)
    switched_off = twin("quiet@example.com", LearningTrack::OFF, suggestions: false,
                        cutoffs: { "pattern" => { "level" => "junior", "through" => "2026-10-13" } })

    [ on_track, opted_out, switched_off ].each do |user|
      actual = prompts_for(user)
      expect(actual).to eq(baseline), -> { first_difference(baseline, actual) }
    end
  end

  let(:state_readers) do
    /learning_track|LearningTrack|level_suggestion|LevelSuggestion|TrackGraduation|shown_level_suggestions/x
  end

  it "keeps track and suggestion state out of generation, review, judges, ConceptMastery and KindDifficulty" do
    own = %w[app/services/level_suggestion.rb app/services/level_suggestion/evidence.rb]
    files = Rails.root.glob("app/{services,jobs}/**/*.rb").map { |file| file.relative_path_from(Rails.root).to_s } +
            %w[app/models/concept_mastery.rb app/models/judge_verdict.rb
               app/models/review_prose_verdict.rb app/models/kind_difficulty.rb]

    readers = (files - own).select { |file| File.read(Rails.root.join(file)).match?(state_readers) }
    expect(readers).to eq([])
  end

  it "would catch a reader of each name it guards" do
    %w[learning_track LearningTrack level_suggestion_cutoffs level_suggestions LevelSuggestion
       TrackGraduation shown_level_suggestions level_suggestion_answers].each do |name|
      expect("user.#{name}").to match(state_readers)
    end
  end
end
