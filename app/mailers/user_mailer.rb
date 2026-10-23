class UserMailer < ApplicationMailer
  # Minted here, not passed in, so the plain code is never a job argument, which the queue stores and the enqueue log prints.
  def login_code(user)
    @user     = user
    @raw_code = user.generate_login_code!
    mail(to: user.email)
  end
end
