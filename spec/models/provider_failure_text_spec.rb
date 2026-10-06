require "rails_helper"

RSpec.describe ProviderFailureText do
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

  it "reads an unknown kind as other and an unknown variant as own_key" do
    sentence = text("trial_ended", surface: :critique, variant: "trial").full
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
