class UserMailer < ApplicationMailer
  SECOND_FACTOR_CHANGES = %w[enabled disabled recovery_codes].index_by(&:itself).freeze

  def login_code(user, raw_code)
    @user     = user
    @raw_code = raw_code
    mail(to: user.email)
  end

  def second_factor_changed(user, change, changed_at)
    @user       = user
    @change     = SECOND_FACTOR_CHANGES.fetch(change)
    @changed_at = changed_at.in_time_zone(user.effective_time_zone)
    mail(to: user.email)
  end
end
