# app/views/sessions/new.html.erb

## Pending login banner

The pending-login state renders as a banner above the login form and never
replaces it. A login can fail to complete in this browser: the code was
requested in a different browser, it was already used, or it died after five
wrong guesses. When the pending state replaced the form, the page offered no
way to request a new code, and the only recovery was clearing cookies.
