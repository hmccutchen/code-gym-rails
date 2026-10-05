# Prompt-injection red team for the review grader, the section judge and the
# duck. Billed to ANTHROPIC_API_KEY, never to a stored user key. Never run in CI.
#
#   ANTHROPIC_API_KEY=sk-ant-... bin/rails runner script/security_audit/red_team.rb
require_relative "prompt_injection_red_team"

api_key = ENV["ANTHROPIC_API_KEY"].presence or abort("ANTHROPIC_API_KEY is not set. Calls are billed to it, never to a user's stored key.")
PromptInjectionRedTeam.new(api_key: api_key).run
