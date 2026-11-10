# config/locales/en.yml

## provider_failures

Each kind of provider failure has one sentence group, rendered when a page is read (`ProviderFailureText`). Each kind has a variant per credential, and a variant missing an entry falls back to `own_key`.

The placeholders mean:

- `%{outcome}`: the surface's line from `outcomes`.
- `%{provider}`: the provider's label.
- `%{time}` and `%{day}`: the reset, in the reader's zone.
- `%{wait}`: a short wait, in words.

## date and time formats

Pages and emails write a date with `l(value, format: :name)`, so each shape is
set once under `date.formats` or `time.formats`. A `Date` reads `date.formats`
and a `Time` reads `time.formats`, so a shape used for both is listed in both.
Rails' own English formats pad the day (`November 03, 2026`); `long` here
overrides them with `%-d`, as every other format does.

`ProviderFailureText` and `PushNudgePlan` still call `strftime` for an hour or
a weekday on its own.
