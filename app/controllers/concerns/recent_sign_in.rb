# Design notes: docs/code-notes/app/controllers/concerns/recent_sign_in.md
module RecentSignIn
  extend ActiveSupport::Concern

  included do
    helper_method :signed_in_recently?
  end

  private

  def signed_in_recently?
    User.signed_in_recently?(session[:signed_in_at])
  end

  # Signs out first, so the page saved as return_to is reached only through a fresh sign-in.
  def send_through_sign_in(return_to:, notice:)
    reset_session
    session[:return_to] = return_to
    redirect_to login_path, notice: notice
  end
end
