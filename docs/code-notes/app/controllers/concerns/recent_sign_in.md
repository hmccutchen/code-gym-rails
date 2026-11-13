# app/controllers/concerns/recent_sign_in.rb

`RecentSignIn` is the controller side of "signed in recently". Two actions need it: turning on the authenticator (`AuthenticatorsController#show` and `#create`) and deleting the account (`AccountsController#destroy`).

## `#signed_in_recently?`

It hands `session[:signed_in_at]` to `User.signed_in_recently?`, which reads the stamp through `User.session_time` and compares it with `User::RECENT_SIGN_IN` (15 minutes). The window and the stamp reader stay on the model, so the two actions cannot disagree about what "recent" means. It is a helper method too, so the Account page can say before the click that deleting will ask for a sign-in.

## `#send_through_sign_in`

It runs `reset_session`, saves the page to come back to as `return_to`, and redirects to `/login`. `SignInCompletion#start_new_session_for` reads `return_to` after the next sign-in, the authenticator step included, and sends the browser there.

The return address is always a page the caller names, never the request that was refused. `require_login` saves a return address only for an HTML GET, and a `DELETE /account` must not be replayed by a sign-in: the person lands back on the Account page and presses Delete again, now with a recent sign-in.

"Recent" counts from the sign-in, not from the click: the stamp is the time the sign-in's code was checked, so a session stays recent for 15 minutes after that whatever the person does in between. The authenticator check works the same way.

`reset_session` ends the session only in this browser. Sessions live in a cookie store, so a copy of the old cookie stays valid elsewhere until it expires or `users.sessions_valid_after` moves past its stamp. What stops that copy from deleting the account is the check itself: its signed `signed_in_at` stamp is still old, so `#signed_in_recently?` refuses it too. A borrowed or left-open browser, or a copied cookie, therefore needs the inbox or the authenticator before it can delete the account.
