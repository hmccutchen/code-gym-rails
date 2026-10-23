module PreviewAutoLogin
  extend ActiveSupport::Concern

  # A cookie survives the reset_session that both logout actions call; a session key would be discarded.
  SIGNED_OUT_COOKIE = :preview_signed_out

  # Specs exercise Behavior directly; the `included do` block owns whether the callback enters the chain.
  module Behavior
    private

    def preview_auto_login
      return if current_user
      return if cookies[SIGNED_OUT_COOKIE].present?
      return if controller_name == "sessions"

      user = User.active.find_by(email: PreviewSeed.target_email)
      # Never sign into an account the seeder did not create, and never 500 when seeding failed or the row is gone.
      return unless PreviewSeed.seeded?(user)

      session[:user_id] = user.id
    end

    def remember_preview_sign_out
      destroying_session = action_name == "destroy" &&
                            (controller_name == "sessions" || controller_name == "accounts")
      return unless destroying_session

      # A browser-session cookie: quitting the browser brings auto-login back, acceptable only in a throwaway preview.
      cookies[SIGNED_OUT_COOKIE] = { value: "1", httponly: true }
    end
  end

  include Behavior

  included do
    prepend_before_action :preview_auto_login if PreviewEnvironment.active?
    after_action :remember_preview_sign_out   if PreviewEnvironment.active?
  end
end
