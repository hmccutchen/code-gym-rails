# lib/sign_in_failure_app.rb

Devise's failure app keeps the request's format on its redirect, so a signed-out
JSON request would be sent to `/login.json`. The page scripts only need to see
a redirect, and `/login` is the page a person should land on, so JSON joins
HTML in skipping the format. The initializer names it through a lambda,
because the class is autoloaded and initializers run before autoloading is
allowed.
