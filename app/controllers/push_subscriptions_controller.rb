# #create is JSON because only script can call it; #destroy is a form post so opting out never depends on that script.
class PushSubscriptionsController < ApplicationController
  # Account is reachable without a key, and the layout's re-subscribe script would otherwise 302 to /setup on every launch.
  skip_before_action :require_provider

  MAX_ENDPOINT_LENGTH = 2048

  # Allowlist against SSRF: the worker POSTs to this URL. Add a host here if a refused enrolment is logged for one.
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
      # Enrolment must not walk a ready_and_nudges user back to ready; the layout re-subscribes on every page load.
      current_user.update!(reminder_level: :ready) if current_user.reminders_none?
    end

    head :created
  end

  # PATCH /push_subscription — only moves an enrolled user between levels; enrolment needs a click handler for iOS.
  def update
    return head :not_found unless WebPushCredentials.configured?
    return redirect_to account_path unless current_user.push_reminders_enabled?

    current_user.update!(reminder_level: params[:nudges] == "1" ? :ready_and_nudges : :ready)

    redirect_to account_path, notice: t("flash.push_subscriptions.settings_saved")
  end

  # DELETE /push_subscription — drops endpoints too, or tomorrow's job would push to a browser that asked it to stop.
  def destroy
    User.transaction do
      current_user.push_subscriptions.destroy_all
      current_user.update!(reminder_level: :none)
    end

    redirect_to account_path, notice: t("flash.push_subscriptions.turned_off")
  end

  private

  # Validated where it enters, so PushDelivery can assume an endpoint it can sign for.
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
