# Design notes: docs/code-notes/config/routes.md
Rails.application.routes.draw do
  # Railway's healthcheck target (railway.toml healthcheckPath).
  get "up" => "rails/health#show", as: :rails_health_check

  # format: false, or /manifest.json.html reaches the controller as HTML and 500s on MissingTemplate.
  get "manifest.json" => "rails/pwa#manifest", as: :pwa_manifest, defaults: { format: :json }, format: false

  get "service-worker.js" => "rails/pwa#service_worker", as: :pwa_service_worker, defaults: { format: :js }, format: false

  mount ActionCable.server => "/cable"

  devise_for :users, path: "", skip: :registrations,
                     path_names: { sign_in: "login", sign_out: "logout" },
                     controllers: { sessions: "users/sessions", confirmations: "users/confirmations",
                                    passwords: "users/passwords" }

  devise_scope :user do
    get  "signup", to: "users/registrations#new",    as: :new_user_registration
    post "signup", to: "users/registrations#create", as: :user_registration
  end

  get  "login/first",      to: "first_sign_ins#new",         as: :first_sign_in
  post "login/first",      to: "first_sign_ins#create"
  post "login/first/code", to: "first_sign_ins#verify_code", as: :verify_first_sign_in

  resource :password_setup,   only: [ :edit, :update ]
  resource :two_factor_setup, only: [ :show, :create ]
  resource :backup_codes, only: :create

  get   "setup", to: "api_keys#edit"
  patch "setup", to: "api_keys#update"

  get  "trial/start", to: "trials#new", as: :new_trial
  post "trial/start", to: "trials#start", as: :start_trial
  get  "trial", to: "trials#show"
  post "trial", to: "trials#create"

  get "welcome", to: "welcome#show"

  resource :account, only: [ :show, :destroy ] do
    patch :toggle_generation, on: :member
  end

  resource :push_subscription, only: [ :create, :update, :destroy ]

  root "dashboard#show"

  get "history", to: "history#index"

  get  "learn", to: "learn#index"
  get  "progress", to: "progress#index"
  post "learn/prepare", to: "learn#prepare", as: :prepare_learn
  post "learn/prepare_ladders", to: "learn#prepare_ladders", as: :prepare_learn_ladders
  # Above learn/:bucket/:concept, which would otherwise read "lessons" as a bucket.
  get  "learn/lessons/:lesson", to: "learn_lessons#show", as: :learn_lesson
  get  "learn/:bucket/:concept", to: "learn#show", as: :learn_concept
  post "learn/:bucket/:concept/prepare", to: "learn#prepare_concept", as: :prepare_learn_concept
  get  "learn/:bucket/:concept/status", to: "learn#status", as: :learn_concept_status
  post   "learn/:bucket/:concept/drill",      to: "concept_drills#create",        as: :learn_concept_drill
  delete "learn/:bucket/:concept/drill",      to: "concept_drills#destroy"
  post   "learn/:bucket/groups/:group/drill", to: "concept_drills#create_group",  as: :learn_group_drill
  delete "learn/:bucket/groups/:group/drill", to: "concept_drills#destroy_group"

  patch "profile", to: "profile#update", as: :profile
  patch "daily_kinds/:place", to: "daily_kinds#update", as: :daily_kind

  post "level_suggestion/dismissal", to: "level_suggestion_dismissals#create", as: :level_suggestion_dismissal
  post "level_suggestion/answer", to: "level_suggestion_answers#create", as: :level_suggestion_answer

  post "regenerate", to: "daily_exercises#regenerate"

  post "generate", to: "daily_exercises#generate"

  get "dashboard/status", to: "dashboard#status", as: :dashboard_status

  resources :responses, only: [ :create ] do
    member do
      post :review
      get :review_status
      post :email_review
      post :explain_differently
      post :follow_ups
      delete :start_over
    end
    collection do
      post :duck_thread
      delete :duck_thread, action: :clear_duck_thread
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
