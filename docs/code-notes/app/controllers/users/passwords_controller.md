# app/controllers/users/passwords_controller.rb

## `#sign_in_after_reset_password?`

A reset signs in only an account without an authenticator. That account
cannot sign in through the form, so the reset is one of its ways in, and the
setup checks send it straight to enroll. An account with an authenticator is
not signed in, so it still needs its code.
