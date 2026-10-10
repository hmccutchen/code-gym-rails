# API key for production's :resend delivery method; unset in development and test.
Resend.api_key = ENV["RESEND_API_KEY"] if ENV["RESEND_API_KEY"].present?
