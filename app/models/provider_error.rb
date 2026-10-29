# Design notes: docs/code-notes/app/models/provider_error.md
class ProviderError < StandardError
  attr_reader :http_status, :quota_id, :retry_after
  attr_accessor :provider

  def initialize(message = nil, http_status: nil, quota_id: nil, retry_after: nil)
    super(message)
    @http_status = http_status
    @quota_id    = quota_id
    @retry_after = retry_after
  end

  def self.error_code = "other"

  def self.failure_code = "provider_error"

  # nil leaves the reason to the HTTP status or the error code, which AiService.judge_fallback_reason reads next.
  def self.judge_fallback_reason = nil

  def self.failure_kind = nil

  def self.leaves_tokens_unknown? = false

  class AuthenticationError < ProviderError
    def self.error_code = "authentication"
    def self.failure_code = "authentication"
    def self.failure_kind = "bad_key"
  end

  class RateLimitError < ProviderError
    def self.error_code = "rate_limit"
    def self.failure_code = "rate_limit"
  end

  class BillingError < ProviderError
    def self.error_code = "out_of_credit"
    def self.failure_code = "out_of_credit"
    def self.failure_kind = "out_of_credit"
  end

  class TrialEndedError < ProviderError
    def self.error_code = "trial_ended"
    def self.failure_kind = "trial_ended"
  end

  class TrialAllowanceError < ProviderError
    def self.error_code = "trial_allowance_used"
    def self.failure_kind = "trial_allowance_used"
  end

  class NetworkError < ProviderError
    def self.failure_code = "network"
    def self.failure_kind = "outage"
  end

  class TimeoutError < ProviderError
    def self.failure_code = "timeout"
    def self.judge_fallback_reason = "timeout"
    def self.failure_kind = "timeout"
    # The provider may have run and billed part of the call before the read gave up.
    def self.leaves_tokens_unknown? = true
  end

  class InvalidResponseError < ProviderError
    def self.error_code = "invalid_response"
    def self.failure_code = "invalid_response"
    def self.judge_fallback_reason = "invalid_json"
  end

  class UnusableSectionError < InvalidResponseError
    attr_reader :code

    def initialize(message = nil, code: nil, **options)
      super(message, **options)
      @code = code
    end
  end

  class TruncatedResponseError < InvalidResponseError
    def self.failure_code = "truncated"
    def self.judge_fallback_reason = "truncated"
  end

  class RefusalError < ProviderError
    def self.failure_code = "refusal"
    def self.judge_fallback_reason = "refusal"
  end

  class UnsupportedRouteError < ProviderError; end

  class DeadlineError < TimeoutError
    def initialize(purpose = nil)
      super("The generation deadline left no time for a #{purpose || "further"} call.")
    end

    def self.judge_fallback_reason = "deadline"
    def self.leaves_tokens_unknown? = false
  end

  class AllSectionsRejectedError < ProviderError
    def initialize(message = "Every section of today's draft failed its quality check, so no set was saved. Try generating again.")
      super
    end
  end
end
