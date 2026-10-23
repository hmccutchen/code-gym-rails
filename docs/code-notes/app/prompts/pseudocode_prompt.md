# `PseudocodePrompt`

The pseudocode critique and translation prompts, moved out of `AiService` (#431). `AiService#critique_pseudocode` and `#translate_pseudocode` still make the calls and check the replies.

## `TRANSLATE_SYSTEM`

Its rules are stated as prohibitions because a model reads the adjective
"faithful" generously, and the translation drifts into free help.
