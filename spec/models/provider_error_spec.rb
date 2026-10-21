require "rails_helper"

RSpec.describe ProviderError do
  it "carries the HTTP status, quota id and retry wait it was raised with, and a writable provider" do
    error = described_class.new("slow down", http_status: 429, quota_id: "PerDay", retry_after: 30)
    error.provider = "gemini"

    expect(error).to have_attributes(message: "slow down", http_status: 429, quota_id: "PerDay", retry_after: 30, provider: "gemini")
  end

  it "keeps the subclass order the classifiers depend on" do
    expect(ProviderError::TruncatedResponseError.superclass).to eq(ProviderError::InvalidResponseError)
    expect(ProviderError::DeadlineError.superclass).to eq(ProviderError::TimeoutError)
    %w[AuthenticationError RateLimitError BillingError TrialEndedError TrialAllowanceError NetworkError TimeoutError
       InvalidResponseError RefusalError UnsupportedRouteError AllSectionsRejectedError].each do |name|
      expect(ProviderError.const_get(name).superclass).to eq(described_class)
    end
  end

  it "names the call a deadline stopped, and the judge's fallback reason for it" do
    expect(ProviderError::DeadlineError.new("judge_section").message).to include("no time for a judge_section call")
    expect(ProviderError::DeadlineError.new.message).to include("no time for a further call")
    expect(ProviderError::DeadlineError.judge_fallback_reason).to eq("deadline")
  end

  # error code, ApiUsage failure code, judge fallback reason (nil: the status or error code), person-facing kind (nil: by status).
  CODES = {
    "ProviderError"                           => [ "other", "provider_error", nil, nil ],
    "ProviderError::AuthenticationError"      => [ "authentication", "authentication", nil, "bad_key" ],
    "ProviderError::RateLimitError"           => [ "rate_limit", "rate_limit", nil, nil ],
    "ProviderError::BillingError"             => [ "out_of_credit", "out_of_credit", nil, "out_of_credit" ],
    "ProviderError::TrialEndedError"          => [ "trial_ended", "provider_error", nil, "trial_ended" ],
    "ProviderError::TrialAllowanceError"      => [ "trial_allowance_used", "provider_error", nil, "trial_allowance_used" ],
    "ProviderError::NetworkError"             => [ "other", "network", nil, "outage" ],
    "ProviderError::TimeoutError"             => [ "other", "timeout", "timeout", "timeout" ],
    "ProviderError::DeadlineError"            => [ "other", "timeout", "deadline", "timeout" ],
    "ProviderError::InvalidResponseError"     => [ "invalid_response", "invalid_response", "invalid_json", nil ],
    "ProviderError::TruncatedResponseError"   => [ "invalid_response", "truncated", "truncated", nil ],
    "ProviderError::RefusalError"             => [ "other", "refusal", "refusal", nil ],
    "ProviderError::UnsupportedRouteError"    => [ "other", "provider_error", nil, nil ],
    "ProviderError::AllSectionsRejectedError" => [ "other", "provider_error", nil, nil ]
  }.freeze

  it "has every error class state its codes here, so a new subclass is a decision rather than a silent fall-through" do
    Rails.application.eager_load!

    expect(([ described_class ] + described_class.descendants).map(&:name)).to match_array(CODES.keys)
  end

  CODES.each do |name, (error_code, failure_code, judge_reason, failure_kind)|
    it "gives #{name} its codes, inherited unless it states its own" do
      expect(name.constantize).to have_attributes(error_code: error_code, failure_code: failure_code,
                                                  judge_fallback_reason: judge_reason, failure_kind: failure_kind)
    end
  end

  it "explains a fully rejected draft by default" do
    expect(ProviderError::AllSectionsRejectedError.new.message).to start_with("Every section of today's draft failed its quality check")
  end
end
