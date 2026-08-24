# Transparent login for a Railway PR app: opening the deployment URL lands the
# reviewer on the dashboard rather than a login form they have no mailbox for.
#
# The gate is checked at class-definition time, not per request: unless
# PREVIEW_APP is set at boot, the callback is never added to the chain, so a
# non-preview deployment has no path that could run this — not one that declines
# at request time. What that safety rests on is PREVIEW_APP being reserved for
# pull-request deployments: railway.toml exports it only from
# [environments.pr.deploy], and nothing in the app sets it. It is still an
# ordinary environment variable, so setting it by hand on a production service
# would enable this — that variable is the thing to keep un-set, and the reason
# PreviewEnvironment documents it as such.
module PreviewAutoLogin
  extend ActiveSupport::Concern

  # Survives reset_session, which both SessionsController#destroy and
  # AccountsController#destroy call — a session key would be discarded by the
  # very action that needs to set it. Using a cookie also keeps every line of
  # preview-only logic inside this module instead of editing the shared logout
  # path.
  SIGNED_OUT_COOKIE = :preview_signed_out

  # Extracted so the behavior is testable without the registration decision:
  # specs exercise Behavior directly, while the `included do` block below owns
  # the decision about whether the callback ever enters the chain.
  module Behavior
    private

    def preview_auto_login
      return if current_user
      return if cookies[SIGNED_OUT_COOKIE].present?
      # Code login must behave exactly as it does everywhere else, and
      # staying out of this controller is what keeps that flow exercisable here.
      return if controller_name == "sessions"

      user = User.active.find_by(email: PreviewSeed.target_email)
      # Seeding may have failed, the account may have been deleted through the
      # Account page, or the row may be a real user PreviewSeed refused to touch.
      # A convenience must neither become a 500 nor sign anyone into an account
      # this seeder did not create.
      return unless PreviewSeed.seeded?(user)

      session[:user_id] = user.id
    end

    def remember_preview_sign_out
      destroying_session = action_name == "destroy" &&
                            (controller_name == "sessions" || controller_name == "accounts")
      return unless destroying_session

      # No expires: a browser-session cookie. Quitting the browser (not just
      # closing the tab) drops it, so auto-login comes back on the next visit
      # — acceptable in a throwaway preview app, not something to carry into
      # a real deployment.
      cookies[SIGNED_OUT_COOKIE] = { value: "1", httponly: true }
    end
  end

  include Behavior

  included do
    prepend_before_action :preview_auto_login if PreviewEnvironment.active?
    after_action :remember_preview_sign_out   if PreviewEnvironment.active?
  end
end
