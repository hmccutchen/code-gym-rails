# Design notes: docs/code-notes/app/controllers/concerns/sign_in_completion.md
module SignInCompletion
  PENDING_SECOND_FACTOR = :pending_second_factor

  private

  def complete_sign_in(user, checked_at:)
    trial = PendingTrial.take(session)
    destination = start_new_session_for(user, checked_at)
    return finish_pending_trial(user, trial) if trial

    redirect_to destination || root_path, notice: t("sessions.welcome_back", name: user.name)
  end

  def start_second_factor_challenge(user)
    session.delete(:pending_login_email)
    session.delete(:pending_login_at)
    session[PENDING_SECOND_FACTOR] = { "user_id" => user.id,
                                       "at" => User.session_stamp(user.issue_second_factor_challenge!) }
    redirect_to second_factor_challenge_path
  end

  def pending_second_factor
    marker = session[PENDING_SECOND_FACTOR]
    marker.is_a?(Hash) ? marker : {}
  end

  def finish_pending_trial(user, trial)
    case trial.start_for(user)
    when :started     then redirect_to root_path, notice: t("trials.started")
    when :has_own_key then redirect_to setup_path, alert: t("trials.has_own_key")
    else                   redirect_to trial_path, alert: t("trials.code_rejected")
    end
  end

  # Read return_to before reset_session, which discards everything written before authentication.
  def start_new_session_for(user, checked_at)
    destination = session[:return_to]
    reset_session
    session[:user_id]      = user.id
    # Taken before the code check, so an authenticator change that commits after that check still ends this session.
    session[:signed_in_at] = User.session_stamp(checked_at)
    destination
  end
end
