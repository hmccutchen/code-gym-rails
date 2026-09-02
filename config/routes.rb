Rails.application.routes.draw do
  # Railway healthcheck target (railway.toml healthcheckPath). Returns 200 once the
  # app has booted; served by Rails' built-in health controller, no auth required.
  get "up" => "rails/health#show", as: :rails_health_check

  # Web app manifest. Linked from the layout, this is what lets an iOS
  # home-screen launch open standalone instead of inside Safari's chrome.
  # Rails' own PwaController does not inherit ApplicationController, so it is
  # reachable logged out — which it must be, since the manifest is fetched
  # before any session exists.
  # format: false, not just a default: the route would otherwise compile to
  # /manifest.json(.:format), and a request-supplied format beats the default —
  # /manifest.json.html then reaches the controller as HTML and raises
  # MissingTemplate, a 500 on an unauthenticated path any crawler can hit.
  get "manifest.json" => "rails/pwa#manifest", as: :pwa_manifest, defaults: { format: :json }, format: false

  # Not used by anything live today — the dashboard's generation-completion
  # signal is a polled JSON endpoint instead (this app loads no Turbo/
  # Stimulus JS, so a broadcast here would have no subscriber). Left mounted
  # rather than removed, as that's a separate, unrelated cleanup.
  mount ActionCable.server => "/cable"

  # Auth (emailed 6-digit code)
  get    "login",        to: "sessions#new"
  post   "login",        to: "sessions#create"
  post   "login/code",   to: "sessions#verify_code", as: :verify_login_code
  delete "logout",       to: "sessions#destroy", as: :logout

  # First-time setup: enter an Anthropic or Gemini API key
  get   "setup", to: "api_keys#edit"
  patch "setup", to: "api_keys#update"

  # Account page: log out or permanently delete (anonymize) the account.
  # Singular resource — a user has exactly one.
  resource :account, only: [ :show, :destroy ] do
    patch :toggle_generation, on: :member
  end

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
      patch :self_explanation # save the user's own restatement of why a fix works
      post :explain_differently # regenerate one section's feedback with a new framing
      post :follow_ups # ask a clarifying question about one section's review
      delete :start_over # clear today's answers/ratings/feedback so the same set can be re-attempted
    end
    collection do
      # Pre-submission Socratic thinking partner. No :id — fully unpersisted,
      # nothing to look up by id.
      post :duck_thread

      # The two pseudocode_to_code rounds. No :id for the same reason
      # duck_thread has none: both run before submission, against today's
      # response, which may not exist yet on the first call.
      post :pseudocode_critique
      post :pseudocode_translate
    end
  end

  # A second framing of one cached concept reference, on demand from inside the
  # reference's own disclosure. Nothing is created — the framing lives in the
  # tab that asked for it, like the duck thread — so this is a verb on the
  # reference, not a nested resource. It still takes an :id, which duck_thread
  # does not: the reference's text must be read from the server's row rather
  # than accepted from the client.
  resources :concept_references, only: [] do
    member do
      post :explain_differently
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
