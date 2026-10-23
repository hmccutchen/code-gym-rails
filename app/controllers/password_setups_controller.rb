# Design notes: docs/code-notes/app/controllers/password_setups_controller.md
class PasswordSetupsController < ApplicationController
  skip_before_action :require_password, :require_two_factor, :require_provider
  before_action :require_no_password

  # GET /password_setup/edit
  def edit; end

  # PATCH /password_setup
  def update
    current_user.password_required = true
    if current_user.update(params.require(:user).permit(:password, :password_confirmation))
      bypass_sign_in(current_user)
      redirect_to two_factor_setup_path, notice: t("password_setups.saved")
    else
      render :edit, status: :unprocessable_content
    end
  end

  private

  def require_no_password
    redirect_to root_path if current_user.password_set?
  end
end
