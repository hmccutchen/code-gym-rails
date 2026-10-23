# Design notes: docs/code-notes/app/controllers/concerns/sign_in_completion.md
module SignInCompletion
  PENDING_SECOND_FACTOR = :pending_second_factor
  REPEAT_WINDOW = 30.seconds

  private

  # A double tap posts twice with the pre-sign-in cookie; the proof holds that browser's own pending stamp and its code.
  def remember_sign_in(user, proof, checked_at)
    Rails.cache.write(sign_in_repeat_key(user), { "digest" => sign_in_repeat_digest(proof), "checked_at" => User.session_stamp(checked_at) },
                      expires_in: REPEAT_WINDOW)
  end

  # The repeat keeps the first post's check time, so sessions ended since then stay ended.
  def recent_sign_in_checked_at(user, proof)
    return if user.nil? || proof.any?(&:blank?)

    remembered = Rails.cache.read(sign_in_repeat_key(user))
    return unless remembered.is_a?(Hash) && ActiveSupport::SecurityUtils.secure_compare(remembered["digest"].to_s, sign_in_repeat_digest(proof))

    User.session_time(remembered["checked_at"]) if user.session_signed_in_valid?(remembered["checked_at"])
  end

  def sign_in_repeat_key(user) = "sign_in_repeat/#{user.id}"

  def sign_in_repeat_digest(proof)
    OpenSSL::HMAC.hexdigest("SHA256", Rails.application.secret_key_base, proof.map(&:to_s).join("\n"))
  end

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
