require "rails_helper"

# A trial and an own-key account with equal settings must send byte-identical requests.
RSpec.describe "Trial isolation", type: :model do
  around { |example| travel_to(Time.utc(2026, 10, 14, 15)) { example.run } }

  def own_key_twin
    User.create!(email: "own@example.com", name: "Twin", time_zone: "UTC", provider: "fake",
                 api_keys: { "fake" => "fake-test-key" }, language: "ruby_rails", learning_track: LearningTrack::OFF)
  end

  def trial_twin
    create_trial_user(email: "trial@example.com", name: "Twin", provider: "fake", house_key: "fake-test-key").tap do |user|
      user.update!(language: "ruby_rails")
    end
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
    expect(result.outcomes).not_to be_empty
    captured.sort_by { |call| [ call[:purpose].to_s, call[:prompt].to_s ] }
  end

  it "sends byte-identical generation and judge prompts on a trial and on an own key" do
    baseline = prompts_for(own_key_twin)
    trial = trial_twin

    expect(prompts_for(trial)).to eq(baseline)
    expect(ApiUsage.where(user: trial).pluck(:house_key).uniq).to eq([ true ])
    expect(ApiUsage.where.not(user: trial).pluck(:house_key).uniq).to eq([ false ])
  end

  it "keeps trial state out of generation, review, judges and ConceptMastery" do
    own = %w[app/models/provider_credential.rb app/models/trial_allowance.rb app/models/house_keys.rb
             app/models/trial_mode.rb app/models/invite_code.rb]
    files = Rails.root.glob("app/{services,jobs}/**/*.rb").map { |file| file.relative_path_from(Rails.root).to_s } +
            %w[app/models/concept_mastery.rb app/models/judge_verdict.rb
               app/models/review_prose_verdict.rb app/models/kind_difficulty.rb]

    readers = (files - own).select do |file|
      File.read(Rails.root.join(file)).match?(/trial_ends_at|trial_active\?|invite_code|HouseKeys|TrialMode/)
    end
    expect(readers).to eq([])
  end
end
