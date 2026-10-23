# app/models/concerns/signed_in_sessions.rb

## Why a session carries a sign-in time

Turning the authenticator on or off has to end every other signed-in browser. A cookie session lives in the browser, so the server can't delete one. Instead, sign-in writes `session[:signed_in_at]`, and a session counts only while that time is at or after `users.sessions_valid_after`. Moving `sessions_valid_after` forward ends every session signed in earlier. The browser that made the change gets a fresh stamp, so it stays signed in.

A session with no stamp, or one that doesn't parse, is rejected. That signs out every session from before this change once, which is the safe direction.

## One lookup for pages and the cable

`ApplicationController#current_user` and `ApplicationCable::Connection` both call `User.signed_in_through`. If the cable kept its own lookup, a websocket opened by an ended session would keep connecting after the pages had signed it out.

## Who writes the stamp

`SignInCompletion#start_new_session_for` and `PreviewAutoLogin` are the only places that sign a session in, and each writes `session[:signed_in_at]` with `User.session_stamp`. A new sign-in path must write it too, or its sessions are rejected on the next request. `spec/requests/preview_auto_login_spec.rb` and `spec/requests/sessions_spec.rb` fail if either stops.
