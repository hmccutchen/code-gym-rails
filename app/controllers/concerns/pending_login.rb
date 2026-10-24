# The one owner of the session keys that make an emailed code redeemable in this browser.
module PendingLogin
  private

  def remember_pending_login(email)
    session[:pending_login_email] = email
    session[:pending_login_at]    = User.session_stamp
  end

  def forget_pending_login
    session.delete(:pending_login_email)
    session.delete(:pending_login_at)
  end

  def pending_login_stamp = session[:pending_login_at]

  def pending_login_address = session[:pending_login_email].presence

  def pending_login_email
    return nil if pending_login_expired?

    pending_login_address
  end

  # An unreadable stamp counts as pending, so a deploy never turns a live code away; Start again clears it.
  def pending_login_expired?
    stamped_at = User.session_time(pending_login_stamp)
    return false if stamped_at.nil?

    !User.login_pending?(email: session[:pending_login_email], requested_at: stamped_at)
  end
end
