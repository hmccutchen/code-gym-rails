# app/controllers/second_factor_challenges_controller.rb

The second sign-in step, reached only from `SessionsController#verify_code` when the account has the authenticator on.

## Every outcome comes from the model

`User#answer_second_factor_challenge!` checks the challenge, verifies the code and settles the counts, all under one row lock, and returns an outcome. The action only maps that outcome to a page. A status it doesn't know raises, so a new outcome can't fall through to a sign-in.

## Ending the challenge

Five wrong codes, expiry and the daily cap each clear `second_factor_challenge_at` on the row, so every copy of the cookie stops working together. The controller also deletes the marker from this browser's session and sends it to `/login`, because only a new emailed code can issue a new challenge.

The daily cap renders the page without its form, with the time the account can try again. Rendering the form would invite codes the model refuses anyway.

## Rate limits

`before_action :require_open_challenge` runs before the rate limits, so a request with no open challenge is turned away without counting. Guessing needs an open challenge, and opening one needs the emailed code.
