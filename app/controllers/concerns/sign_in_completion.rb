# Design notes: docs/code-notes/app/controllers/concerns/sign_in_completion.md
module SignInCompletion
  include PendingLogin

  PENDING_SECOND_FACTOR = :pending_second_factor
  REPEAT_WINDOW = 30.seconds
  WrongFactor = Class.new(StandardError)

  private

  # A double tap posts twice with the pre-sign-in cookie; the proof holds that browser's own pending stamp and its code.
  def remember_sign_in(user, proof, checked_at, challenge_at: nil, notice: nil)
    remembered = { "checked_at" => User.session_stamp(checked_at),
                   "challenge_at" => challenge_at && User.session_stamp(challenge_at), "notice" => notice }
    Rails.cache.write(sign_in_repeat_key(user, proof), remembered, expires_in: REPEAT_WINDOW)
  end

  def recent_sign_in(user, proof)
    return if user.nil? || proof.any?(&:blank?)

    remembered = Rails.cache.read(sign_in_repeat_key(user, proof))
    return unless remembered.is_a?(Hash)
    return unless user.session_signed_in_valid?(remembered["checked_at"])

    { checked_at: User.session_time(remembered["checked_at"]), challenge_at: User.session_time(remembered["challenge_at"]),
      notice: remembered["notice"] }
  end

  def sign_in_repeat_key(user, proof) = "sign_in_repeat/#{user.id}/#{sign_in_repeat_digest(proof)}"

  def sign_in_repeat_digest(proof)
    OpenSSL::HMAC.hexdigest("SHA256", Rails.application.secret_key_base, proof.map(&:to_s).join("\n"))
  end

  # The last check before a session exists, so no sign-in path can finish an authenticator account on the emailed code.
  def complete_sign_in(user, checked_at:, factor:)
    raise WrongFactor, "#{factor} can't finish user #{user.id}'s sign-in" unless finishes_sign_in?(user, factor)

    trial = PendingTrial.take(session)
    destination = start_new_session_for(user, checked_at)
    return finish_pending_trial(user, trial) if trial

    redirect_to destination || root_path, notice: t("sessions.welcome_back", name: user.name)
  end

  def finishes_sign_in?(user, factor)
    case factor
    when :emailed_code  then user.emailed_code_signs_in?
    when :authenticator then user.two_factor_enabled?
    else false
    end
  end

  def start_second_factor_challenge(user, issued_at: nil)
    issued_at ||= user.issue_second_factor_challenge!
    forget_pending_login
    session[PENDING_SECOND_FACTOR] = { "user_id" => user.id,
                                       "at" => User.session_stamp(issued_at) }
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
