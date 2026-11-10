architecture :rails, components: {
  controllers: "app/controllers/**/*.rb",
  models: { in: "app/models/**/*.rb", except: "app/models/ai_provider.rb" },
  helpers: "app/helpers/**/*.rb",
  mailers: "app/mailers/**/*.rb",
  jobs: "app/jobs/**/*.rb",
  services: "app/services/**/*.rb"
}

component :prompts, in: "app/prompts/**/*.rb"
component :clients, in: "app/clients/**/*.rb"
component :forms, in: "app/forms/**/*.rb"
component :provider_registry, in: "app/models/ai_provider.rb"

controllers.can_only_use :prompts, :clients, :forms, :provider_registry

models.cannot_use :services, :clients, :jobs, :forms, :mailers,
  because: "a domain decision never starts a side effect or a provider call; AiProvider, the provider registry, is the one model that names provider classes"
provider_registry.cannot_use :services, :jobs, :forms, :mailers,
  because: "the provider registry names provider classes and nothing else outside the models"
prompts.cannot_use :services, :clients, :controllers, :jobs, :helpers, :forms, :mailers,
  because: "a prompt class is pure text built from values"
clients.cannot_use :controllers, :helpers, :jobs,
  because: "an adapter to the outside never reaches back into the HTTP layer or the job queue"
jobs.cannot_use :controllers, :helpers,
  because: "a job runs outside any request, so it never reaches into the HTTP layer"
mailers.cannot_use :controllers, :jobs, :services,
  because: "a mailer renders a message from the values it is handed"
forms.cannot_use :controllers, :helpers, :jobs, :clients, :services,
  because: "a form validates input and hands values on; it starts no side effect or provider call"
helpers.cannot_use :services, :jobs, :forms, :mailers,
  because: "a helper formats values for a view and starts no side effect"

APP_COMPONENTS = %i[controllers models provider_registry helpers mailers jobs services prompts clients forms].freeze

APP_COMPONENTS.each do |name|
  banned_constants = name == :clients ? %w[Thread] : %w[Thread Faraday]
  public_send(name)
    .cannot_reference_constants(*banned_constants,
      because: "threads start through CallerZoneThread so a fan-out keeps the caller's time zone, and Faraday stays in app/clients, where provider requests are built")
    .cannot_call(:send, :__send__,
      because: "send skips a method's privacy")
    .cannot_call(:call, receiver: "ExerciseDraft",
      because: "a draft is taken only inside AiService, which judges every draft")
end
