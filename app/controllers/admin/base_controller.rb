module Admin
  # Admins come from ADMIN_EMAILS rather than a column on User, avoiding a migration for a single-purpose tool.
  class BaseController < ApplicationController
    before_action :require_admin!

    private

    def require_admin!
      return if admin?

      redirect_to root_path, alert: t("flash.admin.not_authorized")
    end

    def admin?
      admin_emails.include?(current_user.email.to_s.downcase)
    end

    def admin_emails
      ENV.fetch("ADMIN_EMAILS", "").split(",").map { |e| e.strip.downcase }
    end
  end
end
