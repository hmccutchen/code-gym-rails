Rails.application.routes.draw do
  # Auth (magic link)
  get  "login",        to: "sessions#new"
  post "login",        to: "sessions#create"
  get  "auth/verify",  to: "sessions#verify", as: :verify_auth
  delete "logout",     to: "sessions#destroy", as: :logout

  # First-time setup: enter Anthropic API key
  get   "setup", to: "api_keys#edit"
  patch "setup", to: "api_keys#update"

  # Core app
  root "dashboard#show"

  # Submit/update today's answers
  resources :responses, only: [ :create ] do
    member do
      patch :feedback   # rating + feedback_text after submission
      post  :review     # trigger Claude inline review
    end
  end
end
