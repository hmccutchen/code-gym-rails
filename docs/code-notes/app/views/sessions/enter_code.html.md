# app/views/sessions/enter_code.html.erb

## A page of its own

Once a code is requested, the code field moves to `GET /login/code`, and
`GET /login` redirects there for as long as the sign-in is pending. A reload,
or the home-screen app reopening, then lands back on the code field instead
of an email form that would mail a new code and kill the one being read.

## Start again is a button

A login can fail to finish in this browser: the code was requested in another
browser, it was already used, or it died after five wrong guesses. Start
again sends `DELETE /login/code`, which forgets the pending sign-in and goes
to the email form. A plain link to `/login` would only redirect back here.
When the pending sign-in has lapsed on its own, a wrong code sends the
browser to the email form with the reason.
