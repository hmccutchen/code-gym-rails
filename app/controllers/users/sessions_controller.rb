# Design notes: docs/code-notes/app/controllers/users/sessions_controller.md
class Users::SessionsController < Devise::SessionsController
  include PostedUserEmail

  RATE_LIMIT_STORE = LazyCacheStore.new
  ATTEMPT_WINDOW = 15.minutes

  # Prepended ahead of Devise's allow_params_authentication!, or rendering the refusal would sign the posted user in.
  rate_limit to: 10, within: ATTEMPT_WINDOW, by: -> { posted_user_email }, with: -> { attempts_limited },
             store: RATE_LIMIT_STORE, name: "sign_in_for_address", only: :create, prepend: true
  rate_limit to: 20, within: ATTEMPT_WINDOW, with: -> { attempts_limited },
             store: RATE_LIMIT_STORE, name: "sign_in_by_ip", only: :create, prepend: true

  private

  def attempts_limited
    self.resource = resource_class.new(email: posted_user_email)
    flash.now[:alert] = t("sessions.rate_limited.sign_in_attempts")
    render :new, status: :too_many_requests
  end
end
