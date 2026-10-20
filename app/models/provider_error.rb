class ProviderError < StandardError
  attr_reader :http_status, :quota_id, :retry_after
  attr_accessor :provider

  def initialize(message = nil, http_status: nil, quota_id: nil, retry_after: nil)
    super(message)
    @http_status = http_status
    @quota_id    = quota_id
    @retry_after = retry_after
  end

  class AuthenticationError < ProviderError; end

  class RateLimitError < ProviderError; end

  class BillingError < ProviderError; end

  class TrialEndedError < ProviderError; end

  class TrialAllowanceError < ProviderError; end

  class NetworkError < ProviderError; end

  class TimeoutError < ProviderError; end

  class InvalidResponseError < ProviderError; end

  class TruncatedResponseError < InvalidResponseError; end

  class RefusalError < ProviderError; end

  class UnsupportedRouteError < ProviderError; end

  class DeadlineError < TimeoutError
    def initialize(purpose = nil)
      super("The generation deadline left no time for a #{purpose || "further"} call.")
    end

    FALLBACK_REASON = "deadline".freeze
  end

  class AllSectionsRejectedError < ProviderError
    def initialize(message = "Every section of today's draft failed its quality check, so no set was saved. Try generating again.")
      super
    end
  end
end
