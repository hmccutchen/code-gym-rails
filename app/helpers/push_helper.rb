module PushHelper
  # Keyed by the controller's own prefix, so both push controllers read one statement of these four values.
  def push_settings_data(controller)
    { "#{controller}_vapid_key_value" => WebPushCredentials.public_key,
      "#{controller}_register_path_value" => push_subscription_path,
      "#{controller}_known_endpoints_value" => known_push_endpoints.to_json,
      "#{controller}_register_failed_text_value" => t("push.register_failed") }
  end

  def known_push_endpoints
    return [] unless current_user.push_reminders_enabled?

    current_user.push_subscriptions.pluck(:endpoint)
  end
end
