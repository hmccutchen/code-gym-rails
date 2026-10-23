# The address a Devise form posted, normalized as Devise normalizes it, for keying rate limits.
module PostedUserEmail
  private

  def posted_user_email
    posted = params[:user]
    (posted[:email] if posted.is_a?(ActionController::Parameters)).to_s.strip.downcase
  end
end
