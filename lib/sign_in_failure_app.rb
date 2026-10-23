# Design notes: docs/code-notes/lib/sign_in_failure_app.md
class SignInFailureApp < Devise::FailureApp
  private

  def skip_format?
    super || request_format.to_s == "json"
  end
end
