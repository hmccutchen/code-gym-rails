# Rails' default key for this app, stated so adding expire_after can't rotate it and log everyone out.
Rails.application.config.session_store :cookie_store,
  key: "_code_gym_rails_session",
  expire_after: 2.days
