# The one owner of the session key that holds a trial asked for on the trial form until the emailed code is entered.
module PendingTrialSession
  private

  def remember_pending_trial(email:, invite:, provider:, consented_at:)
    session[:pending_trial] = PendingTrial.dump(email: email, invite: invite, provider: provider, consented_at: consented_at)
  end

  def forget_pending_trial = session.delete(:pending_trial)

  # Read once: a login takes it, whatever happens to the trial.
  def take_pending_trial = PendingTrial.load(session.delete(:pending_trial))
end
