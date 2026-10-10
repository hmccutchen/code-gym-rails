# Billed to ANTHROPIC_API_KEY, never a stored user key, and never run in CI.
require_relative "prompt_injection_red_team"

api_key = ENV["ANTHROPIC_API_KEY"].presence or abort("ANTHROPIC_API_KEY is not set. Calls are billed to it, never to a user's stored key.")
PromptInjectionRedTeam.new(api_key: api_key).run
