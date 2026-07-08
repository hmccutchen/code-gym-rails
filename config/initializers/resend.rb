# Resend HTTP API key for ActionMailer's :resend delivery method (production).
# Unset in development/test, where mail is opened in-browser / captured in-memory.
Resend.api_key = ENV["RESEND_API_KEY"] if ENV["RESEND_API_KEY"].present?
