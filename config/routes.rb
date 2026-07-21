Rails.application.routes.draw do
  # Railway healthcheck target (railway.toml healthcheckPath). Returns 200 once the
  # app has booted; served by Rails' built-in health controller, no auth required.
  get "up" => "rails/health#show", as: :rails_health_check

  # Turbo Stream broadcasts (exercise-generation live updates) ride over this.
  mount ActionCable.server => "/cable"

  # Auth (magic link)
  get  "login",        to: "sessions#new"
  post "login",        to: "sessions#create"
  get  "auth/verify",  to: "sessions#verify", as: :verify_auth
  delete "logout",     to: "sessions#destroy", as: :logout

  # First-time setup: enter an Anthropic or Gemini API key
  get   "setup", to: "api_keys#edit"
  patch "setup", to: "api_keys#update"

  # Core app
  root "dashboard#show"

  # Past sessions, newest first
  get "history", to: "history#index"

  # Inline name autosave (JSON)
  patch "profile", to: "profile#update", as: :profile

  # Manually re-run today's exercise generation (capped at once/day in the controller)
  post "regenerate", to: "daily_exercises#regenerate"

  # Manually trigger on-demand generation when the automatic weekday trigger
  # in DashboardController#show intentionally didn't fire (weekends).
  post "generate", to: "daily_exercises#generate"

  # Submit/update today's answers
  resources :responses, only: [ :create, :show ] do
    member do
      patch :feedback     # rating + feedback_text after submission
      post  :review       # trigger Claude inline review
      post  :email_review # email the completed review to the user
    end
  end

  namespace :admin do
    resources :suggested_concepts, only: [ :index ] do
      member do
        patch :promote
        patch :dismiss
      end
    end
  end
end
