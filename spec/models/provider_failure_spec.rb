require "rails_helper"

RSpec.describe ProviderFailure do
  def classify(error) = described_class.classify(error)

  it "reads a per-day quota as a daily limit and any other 429 as a short one" do
    expect(classify(AiService::RateLimitError.new("x", quota_id: "GenerateRequestsPerDayPerProjectPerModel-FreeTier"))).to eq("daily_limit")
    expect(classify(AiService::RateLimitError.new("x", quota_id: "GenerateRequestsPerMinutePerProjectPerModel-FreeTier"))).to eq("short_rate_limit")
    expect(classify(AiService::RateLimitError.new("x", quota_id: "anthropic-ratelimit-input-tokens"))).to eq("short_rate_limit")
    expect(classify(AiService::RateLimitError.new("x"))).to eq("short_rate_limit")
  end

  it "reads a wait of an hour or more as a daily limit whatever the quota is called" do
    expect(classify(AiService::RateLimitError.new("x", retry_after: 3_600))).to eq("daily_limit")
    expect(classify(AiService::RateLimitError.new("x", retry_after: 59))).to eq("short_rate_limit")
  end

  it "reads a server error raised as a rate limit, such as Claude's 529, as an outage" do
    expect(classify(AiService::RateLimitError.new("x", http_status: 529, quota_id: "overloaded_error"))).to eq("outage")
    expect(classify(AiService::RateLimitError.new("x", http_status: 429))).to eq("short_rate_limit")
  end

  it "never reads an empty balance as a limit" do
    expect(classify(AiService::BillingError.new("x", http_status: 429))).to eq("out_of_credit")
  end

  it "maps the remaining classes" do
    expect(classify(AiService::AuthenticationError.new("x", http_status: 400))).to eq("bad_key")
    expect(classify(AiService::TimeoutError.new("x"))).to eq("timeout")
    expect(classify(Timeout::Error.new("x"))).to eq("timeout")
    expect(classify(AiService::NetworkError.new("x"))).to eq("outage")
    expect(classify(AiService::Error.new("x", http_status: 503))).to eq("outage")
    expect(classify(AiService::Error.new("x", http_status: 400))).to eq("other")
    expect(classify(AiService::InvalidResponseError.new("x"))).to eq("other")
    expect(classify(IOError.new("x"))).to eq("other")
  end

  it "answers only its own kinds" do
    expect(described_class::KINDS).to all(satisfy { |kind| described_class.kind?(kind) })
    expect(described_class.kind?("trial_ended")).to be(true)
    expect(described_class.kind?("nonsense")).to be(false)
  end
end
