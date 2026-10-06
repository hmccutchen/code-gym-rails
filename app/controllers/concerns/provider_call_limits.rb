# Per-user limits on the endpoints that bill a provider call to the user's own
# key. Each endpoint already caps one section or one page; these bound a
# script or a stuck client across all of them. The scope is fixed rather than
# the controller's, so every endpoint that declares it shares one hourly and
# one daily count.
module ProviderCallLimits
  extend ActiveSupport::Concern

  HOURLY = 60
  DAILY  = 300
  STORE  = LazyCacheStore.new
  SCOPE  = "provider_calls"

  class_methods do
    def limit_provider_calls(only:)
      { "hourly" => [ HOURLY, 1.hour ], "daily" => [ DAILY, 1.day ] }.each do |name, (to, within)|
        rate_limit to: to, within: within, by: -> { current_user.id }, with: -> { provider_calls_limited },
                   store: STORE, scope: SCOPE, name: name, only: only
      end
    end
  end

  private

  def provider_calls_limited
    render json: { status: "error", error: t("errors.provider_calls_limited") }, status: :too_many_requests
  end
end
