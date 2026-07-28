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

  # Account page: log out or permanently delete (anonymize) the account.
  # Singular resource — a user has exactly one.
  resource :account, only: [ :show, :destroy ]

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

  # Polled by the dashboard while an async generation job is in flight (see
  # dashboard/_generating.html.erb) — this app has no live Turbo/ActionCable
  # connection to push completion, so the page checks in instead.
  get "dashboard/status", to: "dashboard#status", as: :dashboard_status

  # Submit/update today's answers. Rating rides along in #create's payload; there
  # is no per-day show page — /history renders every submitted day, today included.
  resources :responses, only: [ :create ] do
    member do
      post :review       # trigger the inline AI review
      post :email_review # email the completed review to the user
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
