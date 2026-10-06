# Be sure to restart your server when you modify this file.

# Configure parameters to be partially matched (e.g. passw matches password) and filtered from the log file.
# Use this to limit dissemination of sensitive information.
# See the ActiveSupport::ParameterFilter documentation for supported notations and behaviors.
Rails.application.config.filter_parameters += [
  :passw, :email, :secret, :token, :_key, :crypt, :salt, :certificate, :otp, :ssn, :cvv, :cvc
]

# What engineers write and the login code, which would otherwise reach the
# request log. `code` is anchored because entries match as substrings, and a
# bare :code would also hide `pseudocode` and every `code_review` key. The
# push keys are a browser install's encryption keys.
Rails.application.config.filter_parameters += [
  /\Acode\z/, :answers, :message, :question, :pseudocode, :prior_alternates, :thread, :p256dh, :auth
]

# An invite code is a secret, and `_key` does not cover its name.
Rails.application.config.filter_parameters += [ :invite_code ]
