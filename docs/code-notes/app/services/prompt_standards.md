# `PromptStandards`

Prompt text several prompt families share, moved out of `AiService` (#451) so a prompt class never reads its wording from `AiService`. `PLAIN_LANGUAGE_STANDARD` is the app's copy of CLAUDE.md's writing standard; `spec/services/ai_service_spec.rb` fails when the two drift apart.
