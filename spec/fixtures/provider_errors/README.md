# Provider error bodies

Stubbed provider replies used by `spec/requests/provider_failure_characterization_spec.rb`.

The Gemini bodies follow Google's documented `generateContent` error shape
(`error.status`, `error.details[]` with `QuotaFailure`, `Help` and `RetryInfo`
entries). The Interactions API's real 429 body and headers are unconfirmed:
`script/probe_gemini_capacity.rb` records them, and these files are to be
replaced with what it captures.
