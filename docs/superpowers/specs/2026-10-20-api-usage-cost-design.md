# API usage shows money: design

Status: PR 1 in progress; PR 2 not started. Investigated against
`origin/main` at `cf58300` (2026-10-20), revised after review the same day.

## Goal

The `/account` usage section leads with an estimate of what Coding Gym has
cost on the user's own key, this month and today, then a 30-day rate at
recent pace. Provider, requests and token counts stay on the page behind a
disclosure.

Out of scope: new tables, spend caps, alerts. A spend cap ("stop generating
once this month passes $X") is a separate idea and is not designed here.

## Where things stand

- `ApiUsage` rows record `model`, `tokens_in` (uncached input only),
  `tokens_out` (thinking included), `cache_read_tokens`,
  `cache_write_tokens`, `provider`, `failure` and `house_key`
  (`docs/decisions/what-a-usage-row-records.md`). They record no cost.
- `ApiUsage.own_key_totals` feeds `accounts/_api_usage.html.erb`: one table
  row per provider, input summed with both cache counts. House-key rows are
  left out.
- No rate the app bills from exists. The only prices in the repository are
  `ModelComparison::LIST_PRICE_PER_MILLION` in `script/model_comparison.rb`,
  whose code note says nothing that bills reads them. That table is
  incomplete for billing:
  - It covers three Claude models and no Gemini or OpenAI model.
  - It has no per-model cache rates, only flat factors (write ×1.25,
    read ×0.1). The read factor is wrong for Opus 5.5, whose cache read is
    $0.20 per million on a $4 input rate (×0.05).
- Models a row can name today, from each provider's `MODEL_FOR_PURPOSE` and
  `DEFAULT_ROUTE`: `claude-opus-5-5`, `claude-sonnet-5-5`,
  `gemini-3.5-flash`, `gpt-6.1-sol`, `gpt-6-sol`, `gpt-6-astra`.
  `FakeService` writes `fake`. The comparison script also runs
  `claude-haiku-4-5`.
- Nothing in the app formats money. Numbers use `number_with_delimiter`
  with tabular figures. The app has one locale, `en`.
- `app/views/api_keys/_key_guide.html.erb` opens with "No cost figure:
  ApiUsage does not record the model (#237)". That has been false since
  2026-09-30, when rows started recording the model. PR 1 fixes it.

## PR 1: record the cost on each row

1. **Column.** Add a nullable `cost_usd` column to `api_usages`
   (`decimal, precision: 14, scale: 8`). A null value means the cost is
   unknown, which is different from zero. A call with no tokens at all
   records `0`. A refusal or truncation records what its tokens cost, since
   the provider billed for them.
2. **Rates.** Each provider subclass gets a `PRICE_PER_MILLION` table next to
   its routes, keyed by model. Each entry is an `AiService::Price` with
   five fields: `input`, `output`, `cache_write`, `cache_read` (US dollars
   per million tokens) and `checked_on`, the date someone confirmed them
   on the provider's pricing page. Rates are provider facts, so they live in
   the provider class, the same way routes do. A new provider adds its rates
   in its own class. `FakeService` prices `fake` at zero.
3. **Recording.** `AiService#log_usage` computes the cost from the row's
   four token counts and the class's rate for `result[:model]`, then writes
   it with the row. `ApiUsage` receives a number and never looks up a price,
   which keeps `app_source_spec`'s rule that no model names a provider
   class. A model with no rate records `null` and logs a warning. It never
   raises, because `#log_usage` must not break the call it records.
4. **Spec that fails loudly.** A spec walks each provider's
   `MODEL_FOR_PURPOSE` and `DEFAULT_ROUTE` and fails when a routed model
   has no price. Routing a purpose to a new model without pricing it then
   fails CI instead of quietly writing nulls.
5. **One price list.** `script/model_comparison.rb` prices its runs through
   `ClaudeService` and drops `LIST_PRICE_PER_MILLION` and its flat factors.
6. **Rates.** Anthropic's are confirmed from its API reference
   (2026-10-06). Opus 5.5: $4 input, $20 output, $0.20 cache read.
   Sonnet 5.5: $2, $10, $0.20. Haiku 4.5: $1, $5, $0.10. Cache writes use
   the 5-minute cache that `ClaudeService` requests, at 1.25 × input.
   Gemini's and OpenAI's rates have to be confirmed on each provider's own
   pricing page; this session could not reach either. If a routed model has
   prompt-size price tiers, stop and decide before building tier support.

### Existing rows: no backfill

Every row written before PR 1 deploys keeps `cost_usd` null.

A backfill was considered and declined. It would price the roughly three
weeks of rows (from about 2026-10-01) that already name a model. That needs
a data migration, plus checking three providers' price changelogs for that
window, to fill in a figure only the operator would ever see. PR 2's
partial-month line already keeps October honest, and the gap ends when
October does. Don't revive the backfill without a reason this paragraph
doesn't cover.

### Snapshots

PR 1 changes no page snapshot and no prompt or request snapshot. It touches
no view and no request body.

## PR 2: the usage section

### Periods and time zone

Every period is measured in the user's zone (`User#effective_time_zone`),
the zone the table already uses:

- **This month**: from the start of the calendar month in the user's zone
  (`AccountsController#show` already computes this as `@usage_since`) to
  now.
- **Today**: from the start of today in the user's zone to now.
- **Projection window**: whole days ending at the start of today in the
  user's zone (see below).

The month is a calendar month, and the projection is a rate over 30 days.
They are different measures and won't add up to the same thing. The copy
never asks the reader to compare them.

### Wording

The section names the key, not the person, and says once what it can't see.

- Heading: **Estimated cost on your API key**
- Headline: **$3.12 this month · $0.18 today**
- Projection: **At your pace over the last 4 weeks, about $4.20 per 30
  days.** The week count follows the window (2, 3 or 4).
- One muted line under it: **Estimated at list prices in US dollars, so a
  free tier or discount isn't counted. Your provider's console shows what
  you were actually billed and your remaining credit.**

Copy never says "balance", "spent so far", "left", "by the end of the
month" or "this month's projection". Projection copy never uses "this
month". The empty state keeps its current form: "Coding Gym hasn't used
your API key since October 1."

When the month includes rows with a null `cost_usd` (October, from rows
written before PR 1, or a model without a rate), add a line: "Leaves out N
requests made before Coding Gym recorded costs." The headline then sums
only the priced rows, and that line says the total is partial.

### Free tiers and discounts

The app can't learn the rate a key is actually billed at. That covers a
negotiated discount, credits, and a Gemini key on a free-tier project, where
the calls may cost nothing.

The only signal is indirect. A Gemini 429 whose `quota_id` ends in
`-FreeTier` (e.g. `GenerateRequestsPerDayPerProjectPerModel-FreeTier`)
shows the project was on the free tier at that moment. Having no such row
proves nothing, and a project can add billing mid-month. Reading it would
also mean branching on provider in shared code.

So every key sees the estimate. The muted line says it's at list prices and
names the free tier and discounts, which keeps the page from implying a
precision it doesn't have. No per-provider wording and no free-tier
detection.

### The projection

- **Method.** Take the own-key cost over a trailing window of whole weeks,
  then scale it to 30 days (`cost / window_days × 30`). Whole weeks matter
  because generation runs on weekdays only. A window that ends on a Friday
  after four weekdays would overstate the rate by about 40 percent.
- **Window.** The 28 complete days ending at the start of today in the
  user's zone. Today is left out because it isn't finished. When the first
  priced own-key row is more recent than that, use the largest whole number
  of weeks since then.
- **Honesty rule.** Show no projection until the first priced own-key row
  is at least 14 days before the start of today. Two weeks is the shortest
  window that holds two of each weekday. Until then, the line reads: "A
  30-day estimate appears after two weeks of use." If the window cost
  nothing (generation paused, say), hide the line instead of showing $0.
- The code lives as `ApiUsage` class methods (`own_key_cost(user, from:,
  to:)`, `projected_cost_per_30_days(user, now:)`) returning numbers or
  nil, so no new class is needed.

### Amounts under a cent

Use two decimal places everywhere, through `number_to_currency`. An amount
above zero and below one cent reads **less than $0.01**, and zero reads
**$0.00**. More decimal places would read like a meter, and the page has no
other number with more than two. A duck turn at about $0.002 never shows on
its own. It only shows inside totals, so this case comes up only for
"today" early in the day and for a small provider's cost cell. Projections
use the same rule.

### The disclosure

The current table moves into a closed
`<details class="api-usage-detail">` with the summary
"Requests and tokens". It's the same native disclosure used for History's
answers and reviews. Add the class to the layout's chevron selector lists
(`application.html.erb`, the `summary::before` rules), the one place every
disclosure takes its marker from. The table gains a **Cost** column per
provider, with a dash when that provider's rows in the month are all
unpriced. The existing note about failed requests and cache tokens stays
inside the disclosure.

### Trial accounts

A trial account has no key of its own, so it has no own-key rows and keeps
the current empty state, which is already true for it. The section needs no
trial branch, and nothing waits on trials going away. House-key rows still
get `cost_usd` recorded in PR 1, which shows what trials cost the house,
but no page shows that figure to the user. An account that ran a trial and
then added a key sees only rows from its own key, which `own_key_totals`
already enforces.

### Currency

Providers bill in US dollars, and every routed provider's rates are
published in USD. State it once, in the muted line ("in US dollars"),
rather than writing "US$" on each figure. `number_to_currency` under the
`en` locale already prints `$` with two decimal places, so nothing new is
needed for formatting.

### Docs that change

- `.claude/rules/accounts.md`, "Account usage table": no longer "no cost is
  shown".

### Snapshots

- `account.html` changes: the section's markup and copy, and the
  account page's own `<style>` block.
- All six page snapshots (`account`, `dashboard_submitted`,
  `dashboard_swapped_pair`, `dashboard_unsubmitted`, `history`, `setup`)
  change by one CSS line, because the layout's chevron selector list is
  inlined into every page. Nothing else about the other five pages changes.
- No prompt snapshot (`prompt_snapshots`, `family_prompt_snapshots`,
  `duck_prompt_snapshots`) and no request snapshot changes. Neither PR
  touches a prompt or a request body.
- The snapshot user has no usage rows, so `account.html` covers only the
  empty state. The populated view, the projection's 14-day rule, the
  "less than $0.01" string, the zone boundaries and the partial-month line
  get request specs in `spec/requests/accounts_spec.rb`, next to the
  existing table spec.
