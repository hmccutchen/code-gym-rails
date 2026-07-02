class UserMailer < ApplicationMailer
  def magic_link(user, raw_token)
    @user      = user
    @magic_url = verify_auth_url(token: raw_token)
    mail(to: user.email, subject: "Your Code Gym login link")
  end
end
