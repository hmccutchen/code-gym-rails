class Users::RegistrationsController < Devise::RegistrationsController
  include PostedUserEmail

  RATE_LIMIT_STORE = LazyCacheStore.new

  rate_limit to: 10, within: 1.hour, with: -> { sign_ups_limited }, store: RATE_LIMIT_STORE,
             name: "sign_ups_by_ip", only: :create

  private

  def after_inactive_sign_up_path_for(_user)
    new_user_session_path
  end

  def build_resource(hash = {})
    super
    resource.signing_up = true
    resource.password_required = true
  end

  def sign_up_params
    params.require(:user).permit(:name, :email, :password, :password_confirmation)
  end

  def sign_ups_limited
    build_resource(email: posted_user_email)
    flash.now[:alert] = t("registrations.rate_limited")
    render :new, status: :too_many_requests
  end
end
