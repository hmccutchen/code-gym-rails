module Admin
  # Shared gate for every admin-only controller. Gating is a plain env-var
  # allowlist (ADMIN_EMAILS, comma-separated) rather than a persisted role on
  # User — this mirrors the existing TEST_LOGIN_SECRET pattern used for the
  # owner-only login bypass, and avoids a migration for what's currently a
  # single-purpose internal tool.
  class BaseController < ApplicationController
    before_action :require_admin!

    private

    def require_admin!
      return if admin?

      redirect_to root_path, alert: "Not authorized."
    end

    def admin?
      admin_emails.include?(current_user.email.to_s.downcase)
    end

    def admin_emails
      ENV.fetch("ADMIN_EMAILS", "").split(",").map { |e| e.strip.downcase }
    end
  end
end
