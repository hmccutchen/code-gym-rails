Rails.application.config.filter_parameters += [
  :passw, :email, :secret, :token, :_key, :crypt, :salt, :certificate, :otp, :ssn, :cvv, :cvc
]

# `code` is anchored because entries match as substrings; a bare :code would also hide pseudocode and code_review.
Rails.application.config.filter_parameters += [
  /\Acode\z/, :answers, :message, :question, :pseudocode, :prior_alternates, :thread, :p256dh, :auth
]

# Anchored like `code`: a bare :name would hide every key that contains it.
Rails.application.config.filter_parameters += [ /\Aname\z/ ]

# An invite code is a secret, and `_key` does not cover its name.
Rails.application.config.filter_parameters += [ :invite_code ]
