# Provider error bodies

Stubbed provider replies used by `spec/requests/provider_failure_characterization_spec.rb`.

The Gemini bodies follow Google's documented `generateContent` error shape
(`error.status`, `error.details[]` with `QuotaFailure`, `Help` and `RetryInfo`
entries). The Interactions API's real 429 body and headers are unconfirmed:
`script/probe_gemini_capacity.rb` records them, and these files are to be
replaced with what it captures.

`anthropic_401_invalid_key.json` and `openai_401_invalid_key.json` are the
bodies each provider's list-models endpoint returned to a made-up key on
2026-11-12 (the OpenAI one with its masked key shortened), and
`gemini_400_api_key_invalid.json` matches what Gemini's returned the same
day. `spec/clients/key_check_spec.rb` and
`spec/requests/api_key_check_spec.rb` read them through `key_check_fixture`.
