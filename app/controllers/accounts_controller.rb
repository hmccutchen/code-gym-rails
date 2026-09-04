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
  # Sets paused_generation_at to nil or now. While paused, nothing generates
  # unless the user asks for it explicitly (/generate, /regenerate);
  # submitting and reviewing an existing set are never gated by the pause.
  # Resuming also brings forward the set the pause stranded, which the notice
  # names — otherwise an older set would appear on the dashboard unannounced.
  def toggle_generation
    if resume_requested?
      resumed = current_user.resume_generation!
      notice = if resumed
        "Automatic daily generation resumed. The set you had waiting is on your dashboard."
      else
        "Automatic daily generation resumed."
      end
      redirect_to account_path, notice: notice
    else
      # Only stamp a pause that isn't already running. The timestamp is the
      # floor #held_exercise searches from, so re-stamping an already-paused
      # user walks that floor forward past the very set the pause stranded —
      # a second Pause from a stale Account tab would leave it unreachable for
      # good, still breaking the streak, with no way back. Pausing twice means
      # the pause that is already running, not a new one.
      current_user.update!(paused_generation_at: Time.current) unless current_user.paused_generation_at?
      redirect_to account_path, notice: "Automatic daily generation paused."
    end
  end

  private

  # Each button posts the state it wants rather than asking for a flip, so a
  # double-tapped Resume stays a resume. Read as a flip, the second request
  # re-reads a user the first one already unpaused and takes the pause branch —
  # leaving generation paused by two clicks of a button labelled "Resume". The
  # row lock inside #resume_generation! cannot help, since the two requests
  # disagree about the action before either reaches the model.
  #
  # Falls back to flipping when no intent is posted, so the endpoint's original
  # contract still holds for a caller that sends none.
  def resume_requested?
    return params[:paused] == "0" if params.key?(:paused)

    current_user.paused_generation_at?
  end
end
