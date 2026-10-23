# app/controllers/two_factor_setups_controller.rb

## `#show`

The secret is stored when the page is first shown and reused after, so a
reload shows the same QR code the person may already have scanned. It is not
required for sign-in until a code confirms it.

## `#create`

The backup codes are shown in the reply and never again, so this action
renders instead of redirecting. Reloading the page sends the person to the
dashboard, because the account is enrolled by then.
