Rails.application.routes.draw do
  # Railway healthcheck target (railway.toml healthcheckPath). Returns 200 once the
  # app has booted; served by Rails' built-in health controller, no auth required.
  get "up" => "rails/health#show", as: :rails_health_check

  # Auth (magic link)
  get  "login",        to: "sessions#new"
  post "login",        to: "sessions#create"
  get  "auth/verify",  to: "sessions#verify", as: :verify_auth
  # Interim owner-only login bypass (active only when TEST_LOGIN_SECRET is set).
  # Remove after a sending domain is verified -- see CLAUDE.md "What Still Needs Work".
  get "test_login", to: "sessions#test_login"
  delete "logout",     to: "sessions#destroy", as: :logout

  # First-time setup: enter Anthropic API key
  get   "setup", to: "api_keys#edit"
  patch "setup", to: "api_keys#update"

  # Core app
  root "dashboard#show"

  # Past sessions, newest first
  get "history", to: "history#index"

  # Manually re-run today's exercise generation (capped at once/day in the controller)
  post "regenerate", to: "daily_exercises#regenerate"

  # Submit/update today's answers
  resources :responses, only: [ :create ] do
    member do
      patch :feedback     # rating + feedback_text after submission
      post  :review       # trigger Claude inline review
      post  :email_review # email the completed review to the user
    end
  end
end
