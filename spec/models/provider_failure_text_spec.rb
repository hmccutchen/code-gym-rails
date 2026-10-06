require "rails_helper"

RSpec.describe ProviderFailureText, type: :model do
  # Tuesday 10am Eastern; the Gemini allowance then resets at 3am Eastern on Wednesday.
  let(:failed_at) { Time.utc(2026, 10, 6, 14) }
  let(:zone) { "America/New_York" }

  def text(kind, surface: :review, provider: "gemini", now: failed_at, **options)
    described_class.new(kind, provider: provider, surface: surface, failed_at: failed_at, zone: zone, now: now, **options)
  end

  describe "a daily limit, before and after it resets" do
    it "names the reset in the reader's zone while it is ahead" do
      expect(text("daily_limit").full).to eq(
        "Your Gemini key has used today's free allowance, so the review didn't run. Your answers are saved. " \
        "The allowance resets at 3:00 am your time, Wednesday. Try again after that, or add a paid key in Setup."
      )
    end

    it "says the allowance has reset once the time has passed, and drops the wait" do
      expect(text("daily_limit", now: Time.utc(2026, 10, 7, 7, 1)).full).to eq(
        "Your Gemini key has used today's free allowance, so the review didn't run. Your answers are saved. " \
        "The allowance has reset since then, so you can try again."
      )
    end

    it "reads the reset against the clock when the page is rendered later" do
      travel_to(Time.utc(2026, 10, 6, 20)) do
        expect(described_class.new("daily_limit", provider: "gemini", surface: :generation, failed_at: failed_at, zone: zone).full)
          .to include("resets at 3:00 am your time, Wednesday")
      end
      travel_to(Time.utc(2026, 10, 7, 12)) do
        expect(described_class.new("daily_limit", provider: "gemini", surface: :generation, failed_at: failed_at, zone: zone).full)
          .to eq("Your Gemini key has used today's free allowance, so nothing was generated. The allowance has reset since then, so you can try again.")
      end
    end
  end

  describe "a short limit" do
    it "says how long to wait, from the provider's own figure" do
      expect(text("short_rate_limit", surface: :duck, retry_after: 150).brief)
        .to eq("Gemini is limiting requests right now, so the thinking partner didn't answer. Try again in about 3 minutes.")
      expect(text("short_rate_limit", surface: :duck).brief).to end_with("Try again in about a minute.")
    end

    it "says the wait is over once it has passed" do
      expect(text("short_rate_limit", surface: :duck, now: failed_at + 2.minutes).brief)
        .to eq("Gemini is limiting requests right now, so the thinking partner didn't answer. You can try again now.")
    end
  end

  it "keeps the brief form to the first line and what to do" do
    expect(text("bad_key", surface: :follow_up, provider: "anthropic").brief)
      .to eq("Claude didn't accept your API key, so your question wasn't answered. Check the key in Setup.")
    expect(text("bad_key", surface: :follow_up, provider: "anthropic").full)
      .to eq("Claude didn't accept your API key, so your question wasn't answered. Your question is still in the box. Check the key in Setup.")
  end

  it "writes the trial kinds in trial words whatever variant is asked for" do
    expect(text("trial_allowance_used", surface: :generation, retry_after: 1800, variant: "own_key").full).to eq(
      "Your trial has used its Gemini calls for today, so nothing was generated. " \
      "The count resets at 10:30 am your time, Tuesday. Try again after that."
    )
    expect(text("trial_ended", surface: :review, provider: "anthropic").full).to eq(
      "Your trial has ended, so the review didn't run. Your answers are saved. " \
      "Everything you did is still here. Add your own API key in Setup to keep going."
    )
  end

  it "names the trial's key rather than the reader's on the trial variant, and falls back where the words are the same" do
    expect(text("daily_limit", surface: :generation, variant: "trial").full).to eq(
      "The trial's Gemini key has used today's free allowance, so nothing was generated. " \
      "The allowance resets at 3:00 am your time, Wednesday. Try again after that."
    )
    expect(text("bad_key", surface: :duck, variant: "trial").full)
      .to eq("Gemini didn't accept the trial's key, so the thinking partner didn't answer. Your message is still in the box. Tell the person who runs Code Gym.")
    expect(text("timeout", surface: :duck, variant: "trial").full).to eq(text("timeout", surface: :duck).full)
  end

  it "picks the trial variant for a trial account with no key of its own" do
    trial = create_trial_user(provider: "fake")
    expect(described_class.variant_for(trial)).to eq("trial")
    expect(described_class.variant_for(create_user_with_key)).to eq("own_key")
    trial.update!(provider: "anthropic", api_keys: { "anthropic" => "sk-ant-own" })
    expect(described_class.variant_for(trial)).to eq("own_key")
  end

  it "reads an unknown kind as other and an unknown variant as own_key" do
    sentence = text("nonsense", surface: :critique, variant: "nonsense").full
    expect(sentence).to start_with("Gemini sent back something Code Gym couldn't use, so the critique didn't run.")
  end

  # Nothing in the table can carry provider text, a status code or a key,
  # since the only inputs are a kind, a label and times. This holds every
  # sentence the table can produce to that.
  it "never shows provider text, a status code or a key, on any surface for any kind" do
    forbidden = [ /\b[45]\d\d\b/, /AIza/, /sk-/, /quota, please/, /TCPSocket/, /Net::/, /API error/ ]
    ProviderFailure::KINDS.each do |kind|
      described_class::SURFACES.each do |surface|
        AiProvider.keys.each do |provider|
          described_class::VARIANTS.each do |variant|
            [ failed_at, failed_at + 2.days ].each do |now|
              sentence = text(kind, surface: surface, provider: provider, variant: variant, now: now, retry_after: 20).full
              expect(sentence).to be_present
              forbidden.each { |pattern| expect(sentence).not_to match(pattern), "#{kind}/#{surface}/#{provider}: #{sentence}" }
            end
          end
        end
      end
    end
  end
end
