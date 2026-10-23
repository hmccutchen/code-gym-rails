# app/controllers/password_setups_controller.rb

## `#update`

Devise keeps part of the password digest in the session, so changing the
password would sign the user out on the next request. `bypass_sign_in`
stores the new value and keeps them signed in.

## `#require_no_password`

The page only sets a first password. Changing an existing one goes through
the emailed reset, which asks for the authenticator code again afterwards.
