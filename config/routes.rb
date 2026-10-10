Rails.application.routes.draw do
  # Railway's healthcheck target (railway.toml healthcheckPath).
  get "up" => "rails/health#show", as: :rails_health_check

  # format: false, or /manifest.json.html reaches the controller as HTML and 500s on MissingTemplate.
  get "manifest.json" => "rails/pwa#manifest", as: :pwa_manifest, defaults: { format: :json }, format: false

  # Served from the root so the worker's scope covers the whole app; format: false as for the manifest.
  get "service-worker.js" => "rails/pwa#service_worker", as: :pwa_service_worker, defaults: { format: :js }, format: false

  # Unused: the dashboard polls for generation status because the layout loads no Turbo/Stimulus.
  mount ActionCable.server => "/cable"

  # Auth (emailed 6-digit code)
  get    "login",        to: "sessions#new"
  post   "login",        to: "sessions#create"
  post   "login/code",   to: "sessions#verify_code", as: :verify_login_code
  delete "logout",       to: "sessions#destroy", as: :logout

  # First-time setup: enter an Anthropic or Gemini API key
  get   "setup", to: "api_keys#edit"
  patch "setup", to: "api_keys#update"

  # Trial on a house key: signed out with an email, or signed in on an account with no key.
  get  "trial/start", to: "trials#new", as: :new_trial
  post "trial/start", to: "trials#start", as: :start_trial
  get  "trial", to: "trials#show"
  post "trial", to: "trials#create"

  get "welcome", to: "welcome#show"

  # Account page: log out or permanently delete (anonymize) the account.
  resource :account, only: [ :show, :destroy ] do
    patch :toggle_generation, on: :member
  end

  # Not nested under account: one reminder choice, however many browser endpoints back it.
  resource :push_subscription, only: [ :create, :update, :destroy ]

  # Core app
  root "dashboard#show"

  # Past sessions, newest first
  get "history", to: "history#index"

  # The concept library: every concept in the user's vocabularies, met or not.
  get  "learn", to: "learn#index"
  # Which rung each concept is held at, grouped as Learn groups them.
  get  "progress", to: "progress#index"
  post "learn/prepare", to: "learn#prepare", as: :prepare_learn
  post "learn/prepare_ladders", to: "learn#prepare_ladders", as: :prepare_learn_ladders
  # Above learn/:bucket/:concept, which would otherwise read "lessons" as a bucket.
  get  "learn/lessons/:lesson", to: "learn_lessons#show", as: :learn_lesson
  get  "learn/:bucket/:concept", to: "learn#show", as: :learn_concept
  post "learn/:bucket/:concept/prepare", to: "learn#prepare_concept", as: :prepare_learn_concept
  # Polled while a guide is being written; this app loads no Turbo/ActionCable to push completion.
  get  "learn/:bucket/:concept/status", to: "learn#status", as: :learn_concept_status
  # Drills: a concept or a whole display group the user asked to practise.
  post   "learn/:bucket/:concept/drill",      to: "concept_drills#create",        as: :learn_concept_drill
  delete "learn/:bucket/:concept/drill",      to: "concept_drills#destroy"
  post   "learn/:bucket/groups/:group/drill", to: "concept_drills#create_group",  as: :learn_group_drill
  delete "learn/:bucket/groups/:group/drill", to: "concept_drills#destroy_group"

  # Inline name autosave (JSON)
  patch "profile", to: "profile#update", as: :profile

  # "Not now" on a learning track proposal (JSON).
  post "learning_track/dismissal", to: "learning_track_dismissals#create", as: :learning_track_dismissal

  # Manually re-run today's exercise generation (capped at once/day in the controller)
  post "regenerate", to: "daily_exercises#regenerate"

  # Manual generation for days the dashboard's weekday auto-trigger skips (weekends).
  post "generate", to: "daily_exercises#generate"

  # Polled by dashboard/_generating while a generation job runs; nothing pushes completion.
  get "dashboard/status", to: "dashboard#status", as: :dashboard_status

  # No per-day show page: /history renders every submitted day, today included.
  resources :responses, only: [ :create ] do
    member do
      post :review       # trigger the inline AI review
      post :email_review # email the completed review to the user
      post :explain_differently # regenerate one section's feedback with a new framing
      post :follow_ups # ask a clarifying question about one section's review
      delete :start_over # clear today's answers and ratings so the same set can be re-attempted
    end
    collection do
      # Pre-submission thinking partner; unpersisted, so no :id.
      post :duck_thread

      # No :id: it runs before submission, when today's response may not exist yet.
      post :pseudocode_critique
    end
  end

  # Takes an :id so the reference's text is read from the server's row, never from the client.
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
