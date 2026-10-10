# config/locales/en.yml

## provider_failures

Each kind of provider failure has one sentence group, rendered when a page is read (`ProviderFailureText`). Each kind has a variant per credential, and a variant missing an entry falls back to `own_key`.

The placeholders mean:

- `%{outcome}`: the surface's line from `outcomes`.
- `%{provider}`: the provider's label.
- `%{time}` and `%{day}`: the reset, in the reader's zone.
- `%{wait}`: a short wait, in words.
