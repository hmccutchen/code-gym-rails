# Key is Rails' own default for this app name, stated explicitly so the
# expire_after addition below can't silently rotate it and log everyone out.
Rails.application.config.session_store :cookie_store,
  key: "_code_gym_rails_session",
  expire_after: 2.days
