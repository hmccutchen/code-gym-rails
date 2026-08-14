class AccountsController < ApplicationController
  # Without this skip, a user who hasn't added an API key is redirected to
  # /setup before this action runs — and since the nav log-out button now
  # lives on this page, they would have no way to log out or delete.
  skip_before_action :require_api_key

  # GET /account
  def show; end

  # DELETE /account
  # Synchronous and irreversible. Double-submission is safe twice over: once
  # anonymized, `current_user` returns nil so `require_login` redirects before
  # this ever runs, and `anonymize!` no-ops regardless.
  def destroy
    current_user.anonymize!
    reset_session
    redirect_to login_path, notice: "Your account has been deleted."
  end

  # PATCH /account/toggle_generation
  # Flips paused_generation_at between nil and now. While paused, nothing
  # generates unless the user asks for it explicitly (/generate, /regenerate).
  def toggle_generation
    if current_user.paused_generation_at?
      current_user.update!(paused_generation_at: nil)
      redirect_to account_path, notice: "Automatic daily generation resumed."
    else
      current_user.update!(paused_generation_at: Time.current)
      redirect_to account_path, notice: "Automatic daily generation paused."
    end
  end
end
