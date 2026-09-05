# Enrolling and un-enrolling this browser from the daily reminder.
#
# #create is JSON because it can only ever be called from script: the browser
# hands back an endpoint that has to be granted asynchronously first. #destroy
# is an ordinary form post, so turning reminders off never depends on the same
# machinery that turning them on does.
class PushSubscriptionsController < ApplicationController
  # The toggle lives on the Account page, which is reachable without an API key
  # on purpose. Without this skip a keyless user could see the control and not
  # be able to work it — and the layout's re-subscribe script would 302 to
  # /setup on every launch.
  skip_before_action :require_api_key

  MAX_ENDPOINT_LENGTH = 2048

  # A push endpoint is minted by the browser's own push service, so it can only
  # come from a known handful of hosts. Without this the endpoint is an
  # arbitrary URL chosen by whoever is logged in, which the worker then POSTs to
  # every morning from inside the deployment's network — a blind, authenticated
  # SSRF primitive. Matched by domain suffix, so per-region and per-tenant
  # subdomains are covered without enumerating them.
  #
  # Add a host here if a teammate's browser uses a push service this list
  # doesn't name; a rejection is logged with the host so that is diagnosable
  # rather than a silent failure to enrol.
  ALLOWED_ENDPOINT_HOSTS = %w[
    fcm.googleapis.com
    android.googleapis.com
    push.services.mozilla.com
    web.push.apple.com
    notify.windows.com
  ].freeze

  # POST /push_subscription
  def create
    return head :not_found unless WebPushCredentials.configured?
    return head :unprocessable_content unless valid_subscription?

    User.transaction do
      PushSubscription.register!(
        user:       current_user,
        endpoint:   params[:endpoint],
        p256dh_key: params[:p256dh],
        auth_key:   params[:auth]
      )
      current_user.update!(push_reminders_enabled: true)
    end

    head :created
  end

  # DELETE /push_subscription
  # Drops the endpoints as well as the intent. Leaving rows behind would keep
  # tomorrow's job pushing at a browser whose owner just asked it to stop.
  def destroy
    User.transaction do
      current_user.push_subscriptions.destroy_all
      current_user.update!(push_reminders_enabled: false)
    end

    redirect_to account_path, notice: "Daily reminders turned off."
  end

  private

  # Provider-shaped input from the browser, validated where it enters so
  # PushDelivery can assume an endpoint it can actually sign for.
  def valid_subscription?
    params[:p256dh].present? && params[:auth].present? && allowed_endpoint?
  end

  def allowed_endpoint?
    endpoint = params[:endpoint].to_s
    return false unless endpoint.present? && endpoint.length <= MAX_ENDPOINT_LENGTH

    uri = URI.parse(endpoint)
    return false unless uri.is_a?(URI::HTTPS)

    allowed_host?(uri.host)
  rescue URI::InvalidURIError
    false
  end

  def allowed_host?(host)
    return false if host.blank?
    return true if ALLOWED_ENDPOINT_HOSTS.any? { |allowed| host == allowed || host.end_with?(".#{allowed}") }

    Rails.logger.warn("[push] refused enrolment for unrecognised push host: #{host}")
    false
  end
end
