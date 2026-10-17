require "rails_helper"

RSpec.describe "Track choice and level suggestion isolation" do
  around { |example| travel_to(Time.utc(2026, 10, 14, 15)) { example.run } }

  def twin(email, chosen, cutoffs: {}, suggestions: true, levels: ExerciseSection.keys.index_with { "junior" })
    User.create!(
      email: email, name: "Twin", time_zone: "UTC", provider: "fake", api_keys: { "fake" => "fake-test-key" },
      language: "ruby_rails", track_chosen_at: (Time.current if chosen),
      level_suggestion_cutoffs: cutoffs,
      level_suggestions: suggestions, section_kind_levels: levels
    )
  end

  def prompts_for(user)
    calls = Queue.new
    random = Random.new(42)
    allow(WeightedRoll).to receive(:rand) { random.rand }
    allow_any_instance_of(Array).to receive(:shuffle).and_wrap_original do |original, **kwargs|
      original.call(**kwargs, random: random)
    end
    allow_any_instance_of(FakeService).to receive(:call).and_wrap_original do |original, request|
      calls << request.to_h.deep_dup
      original.call(request)
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

  it "sends byte-identical generation and judge prompts with or without a track choice, with suggestions on or off" do
    baseline = prompts_for(twin("legacy@example.com", false))
    chosen = twin("on@example.com", true,
                  cutoffs: { "code_review" => { "level" => "junior", "through" => "2026-10-13" } })
    switched_off = twin("quiet@example.com", true, suggestions: false,
                        cutoffs: { "pattern" => { "level" => "junior", "through" => "2026-10-13" } })

    [ chosen, switched_off ].each do |user|
      actual = prompts_for(user)
      expect(actual).to eq(baseline), -> { first_difference(baseline, actual) }
    end
  end

  it "sends byte-identical calls for targets equal to the skill level and for no targets" do
    preset = prompts_for(twin("preset@example.com", true))
    following = prompts_for(twin("following@example.com", true, levels: {}))

    expect(following).to eq(preset), -> { first_difference(preset, following) }
  end

  let(:state_readers) do
    /learning_track|track_chosen|choose_track|track_change|TrackChange|level_suggestion|LevelSuggestion|TrackGraduation|
     shown_level_suggestions/x
  end

  it "keeps track and suggestion state out of generation, review, judges, ConceptMastery, KindDifficulty and DailyKinds" do
    own = %w[app/services/level_suggestion.rb app/services/level_suggestion/evidence.rb]
    files = Rails.root.glob("app/{services,jobs}/**/*.rb").map { |file| file.relative_path_from(Rails.root).to_s } +
            %w[app/models/concept_mastery.rb app/models/judge_verdict.rb
               app/models/review_prose_verdict.rb app/models/kind_difficulty.rb app/models/daily_kinds.rb]

    readers = (files - own).select { |file| File.read(Rails.root.join(file)).match?(state_readers) }
    expect(readers).to eq([])
  end

  it "would catch a reader of each name it guards" do
    %w[learning_track track_chosen_at choose_track track_change TrackChange level_suggestion_cutoffs
       level_suggestions LevelSuggestion TrackGraduation shown_level_suggestions level_suggestion_answers].each do |name|
      expect("user.#{name}").to match(state_readers)
    end
  end
end
