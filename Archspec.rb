component :models, in: "app/models/**/*.rb", except: "app/models/ai_provider.rb"
component :prompts, in: "app/prompts/**/*.rb"
component :services, in: "app/services/**/*.rb"
component :clients, in: "app/clients/**/*.rb"

models.cannot_use :services, :clients,
  because: "a domain decision never starts a side effect or a provider call; AiProvider, the provider registry, is the one model that names provider classes"
prompts.cannot_use :services, :clients,
  because: "a prompt class is pure text built from values"
