class ReviewMailer < ApplicationMailer
  # On-demand copy of a completed AI review, sent to the user's own address.
  def send_review(daily_response)
    @response = daily_response
    mail(
      to:      daily_response.user.email,
      subject: default_i18n_subject(app_name: t("app_name"), date: daily_response.date.strftime("%A, %B %-d"))
    )
  end
end
