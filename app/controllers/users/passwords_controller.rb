# Design notes: docs/code-notes/app/controllers/users/passwords_controller.md
class Users::PasswordsController < Devise::PasswordsController
  include PostedUserEmail

  RATE_LIMIT_STORE = LazyCacheStore.new

  rate_limit to: 5, within: 15.minutes, by: -> { posted_user_email }, with: -> { resets_limited },
             store: RATE_LIMIT_STORE, name: "reset_requests_for_address", only: :create
  rate_limit to: 20, within: 15.minutes, with: -> { resets_limited },
             store: RATE_LIMIT_STORE, name: "reset_requests_by_ip", only: :create

  private

  def sign_in_after_reset_password?
    !resource.two_factor_enrolled?
  end

  def resets_limited
    self.resource = resource_class.new(email: posted_user_email)
    flash.now[:alert] = t("passwords.rate_limited")
    render :new, status: :too_many_requests
  end
end
