# Design notes: docs/code-notes/app/controllers/users/confirmations_controller.md
class Users::ConfirmationsController < Devise::ConfirmationsController
  include PostedUserEmail

  RATE_LIMIT_STORE = LazyCacheStore.new

  rate_limit to: 5, within: 15.minutes, by: -> { posted_user_email }, with: -> { resends_limited },
             store: RATE_LIMIT_STORE, name: "confirmation_resends_for_address", only: :create
  rate_limit to: 20, within: 15.minutes, with: -> { resends_limited },
             store: RATE_LIMIT_STORE, name: "confirmation_resends_by_ip", only: :create

  # GET /confirmation — following the link proves the inbox, so it signs in and leads to the authenticator.
  def show
    super { |user| sign_in(user) if user.errors.empty? && !user.two_factor_enrolled? }
  end

  private

  def after_confirmation_path_for(_resource_name, user)
    signed_in?(:user) ? after_sign_in_path_for(user) : new_user_session_path
  end

  def resends_limited
    self.resource = resource_class.new(email: posted_user_email)
    flash.now[:alert] = t("confirmations.rate_limited")
    render :new, status: :too_many_requests
  end
end
