# app/controllers/second_factor_challenges_controller.rb

The authenticator step of sign-in. `SessionsController#create` sends an account with the authenticator on here from its address alone, and `#verify_code` sends one here if an emailed code reaches it from the trial form.

## Every outcome comes from the model

`User#answer_second_factor_challenge!` checks the challenge, verifies the code and settles the counts, all under one row lock, and returns an outcome. The action only maps that outcome to a page. A status it doesn't know raises, so a new outcome can't fall through to a sign-in.

## Ending the challenge

Five wrong codes, expiry and the daily cap each clear `second_factor_challenge_at` on the row, so every copy of the cookie stops working together. The controller also deletes the marker from this browser's session and sends it to `/login`, because only a new request at `/login` can issue a new challenge.

The daily cap renders the page without its form, with the time the account can try again. Rendering the form would invite codes the model refuses anyway.

## Rate limits

`before_action :require_open_challenge` runs before the rate limits, so a request with no open challenge is turned away without counting. Guessing needs an open challenge. Opening one needs only the address, so the per-address request limit and the daily cap are what bound guessing; `docs/decisions/passwordless-sign-in.md` has the numbers.
