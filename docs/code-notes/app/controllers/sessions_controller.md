# app/controllers/sessions_controller.rb

## `#verify_code`

A rejected code gets one of two messages. With no pending login in this browser the page renders no code field, so telling the user to retry would point at a field that isn't there; they are told to request a new code instead.

## `#code_attempts_limited` and `#login_code_requests_limited`

A bare 429 would strand the user on an error page, so each renders a page that can carry on. A code attempt over the limit renders the code page when a sign-in is pending, and the email form when none is: the IP-keyed limit can trip with nothing pending, and a code field then would only bounce to `/login`.
