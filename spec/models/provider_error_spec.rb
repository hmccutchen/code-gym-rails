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
    expect(ProviderError::DeadlineError::FALLBACK_REASON).to eq("deadline")
  end

  it "explains a fully rejected draft by default" do
    expect(ProviderError::AllSectionsRejectedError.new.message).to start_with("Every section of today's draft failed its quality check")
  end
end
