class UserMailer < ApplicationMailer
  SECOND_FACTOR_CHANGES = %w[enabled disabled recovery_codes].index_by(&:itself).freeze

  # Minted here, not passed in, so the plain code is never a job argument, which the queue stores and the enqueue log prints.
  def login_code(user)
    @user     = user
    @raw_code = user.generate_login_code!
    mail(to: user.email)
  end

  def second_factor_changed(user, change, changed_at)
    @user       = user
    @change     = SECOND_FACTOR_CHANGES.fetch(change)
    @changed_at = changed_at.in_time_zone(user.effective_time_zone)
    mail(to: user.email)
  end
end
