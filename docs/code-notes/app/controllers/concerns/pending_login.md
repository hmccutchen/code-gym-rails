# app/controllers/concerns/pending_login.rb

`PendingLogin` owns the two session keys that make an emailed code redeemable in this browser: `remember_pending_login` writes them when a code is requested, `forget_pending_login` clears them when the code is used, none is sent, or the person starts again, and `pending_login_email` reads them. `LoginCodeRequests` and `SignInCompletion` both include it, so no controller names the keys.

## `#pending_login_email`

This is the single authority for whether a login is pending in this browser. A state stamped with `pending_login_at` expires with its code. The mailer mints the code when the mail job runs, which can be minutes after the request, so `User.login_pending?` counts `User::LOGIN_CODE_EXPIRY` from the later of the request and the code's `login_code_sent_at`. Counting from the request alone would reject a code the model still accepts.

A stamp that can't be read counts as still pending, so a deploy never turns a live code away. The cost is that `GET /login` keeps sending that browser to the code page until the person presses Start again.
