# app/controllers/users/sessions_controller.rb

## The rate limits are prepended

Devise prepends `allow_params_authentication!` to `create`. Once it has run,
anything that calls `current_user` in the request, such as the layout
rendering a refusal, runs the sign-in strategies against the posted params
and can sign the user in. The limits are prepended after Devise's callbacks
are declared, so they run first and refuse before that can happen.

## `#attempts_limited`

A refused attempt renders the login page with the address still filled in,
rather than a bare 429.
