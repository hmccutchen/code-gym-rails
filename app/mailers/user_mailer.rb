class UserMailer < ApplicationMailer
  def login_code(user, raw_code)
    @user     = user
    @raw_code = raw_code
    mail(to: user.email)
  end
end
