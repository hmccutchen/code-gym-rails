# app/controllers/users/confirmations_controller.rb

## `#show`

Following the link proves the inbox, which is the only proof an account
without an authenticator can give, since a form sign-in always needs a code.
So the link signs the account in, and the setup checks send it to enroll. It
never signs in an account that already has an authenticator, and a used link
cannot sign in again, because a confirmed account cannot be confirmed twice.

## `#after_confirmation_path_for`

It goes through `after_sign_in_path_for`, so a trial started before sign-up
begins here.
