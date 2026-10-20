# API usage shows money: design

Status: proposed, not implemented. Investigated against `origin/main` at
`cf58300` (2026-10-20).

## Goal

The `/account` usage section leads with what Coding Gym has cost on the
user's own key, this month and today, then a monthly projection. Provider,
requests and token counts stay on the page behind a disclosure.

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
  - It includes `claude-haiku-4-5`, which no purpose routes to.
- Models a row can name today, from each provider's `MODEL_FOR_PURPOSE` and
  `DEFAULT_ROUTE`: `claude-opus-5-5`, `claude-sonnet-5-5`,
  `gemini-3.5-flash`, `gpt-6.1-sol`, `gpt-6-sol`, `gpt-6-astra`.
  `FakeService` writes `fake`. `claude-haiku-4-5` and `gpt-6-luna` appear
  only in thinking-off tables and are never routed.
- Nothing in the app formats money. Numbers use `number_with_delimiter`
  with tabular figures. The app has one locale, `en`.
- `app/views/api_keys/_key_guide.html.erb` opens with "No cost figure:
  ApiUsage does not record the model (#237)". That has been false since
  2026-09-30, when rows started recording the model. It gets fixed in PR 1.

## PR 1: record the cost on each row

1. **Column.** Add a nullable `cost_usd` column to `api_usages`
   (`decimal, precision: 14, scale: 8`). A null value means the cost is
   unknown, which is different from zero. A failed call with no tokens
   records `0`. A refusal or truncation records what its tokens cost, since
   the provider billed for them.
2. **Rates.** Each provider subclass gets a `PRICE_PER_MILLION` table next to
   its routes, keyed by model, with five fields: `input`, `output`,
   `cache_write`, `cache_read`, plus the date the rates were checked. Rates
   are provider facts, so they live in the provider class, the same way
   routes do. A new provider adds its rates in its own class.
   `FakeService` prices `fake` at zero.
3. **Recording.** `AiService#log_usage` computes the cost from the row's
   four token counts and the class's rate for `result[:model]`, then writes
   it with the row. `ApiUsage` receives a number and never looks up a price,
   which keeps `app_source_spec`'s rule that no model names a provider
   class. A model with no rate records `null` and logs a warning. It never
   raises, because `#log_usage` must not break the call it records.
4. **Spec that fails loudly.** A spec walks each provider's
   `MODEL_FOR_PURPOSE` and `DEFAULT_ROUTE` and fails when a routed model
   lacks any of the five rates. Routing a purpose to a new model without
   pricing it then fails CI instead of quietly writing nulls.
5. **One price list.** `script/model_comparison.rb` reads the provider
   tables and drops `LIST_PRICE_PER_MILLION` and its flat factors. Two
   lists of the same prices would drift apart, and this one already has.
6. **Rates to fill in.** Anthropic's current rates (checked 2026-10-06):
   Opus 5.5 is $4 input, $20 output and $0.20 cache read per million;
   Sonnet 5.5 is $2, $10 and $0.20. The cache-write rate for the 5-minute
   cache, which `ClaudeService` uses, should be confirmed on the pricing
   page. The repository assumes 1.25 × input. Gemini and OpenAI rates come
   from each provider's own pricing page on the day PR 1 is written. Record
   OpenAI's cache write separately (the decision doc says 1.25 × input) and
   give Gemini's a zero rate, since Gemini reports no cache write. If a
   routed model has prompt-size price tiers, stop and decide before
   building tier support. None of the Claude routes do.

### Existing rows

- **Rows with no model** (everything before the 2026-09-30 change, plus any
  written on 2026-10-01 before that deploy reached production) cannot be
  priced, and their Gemini token counts are wrong too. They stay null for
  good.
- **Rows with a model** run from about 2026-10-01 to the day PR 1 deploys,
  about three weeks. The routed models changed twice in that window (the
  OpenAI routes on 10-01 and 10-05). That doesn't matter, because each row
  names its own model. What matters is whether any provider changed a price
  in the window. The repository can't answer that. Anthropic's rates for
  the two routed Claude models haven't changed since 2026-09-30, as far as
  the API reference shows. Gemini and OpenAI need checking against their
  pricing changelogs.
- **Recommendation: backfill rows that have a model, explicitly.** Leaving
  them null would make October's headline cover only its last week or so.
  Do it in a separate data migration within PR 1. It reads the same rate
  tables, prints how many rows it priced per model and how many it left
  null, and the PR description names the rates used and the date they were
  confirmed. If any provider changed a price during the window, that
  provider's rows stay null. A rate table holding two dates' prices isn't
  worth its code for three weeks of rows.
- To size it, run in production before writing the migration:
  `SELECT provider, model, MIN(created_at), COUNT(*) FROM api_usages WHERE house_key = false GROUP BY 1, 2;`

### Snapshots

PR 1 changes no page snapshot and no prompt or request snapshot. It touches
no view and no request body.

## PR 2: the usage section

### Wording

The section names the key, not the person, and says once what it can't see.

- Heading: **Cost on your API key**
- Headline: **$3.12 this month · $0.18 today**
- Projection: **At this pace, about $4.20 a month.**
- One muted line under it: **What Coding Gym's requests cost at your
  provider's prices, in US dollars. Your provider's console shows your full
  bill and remaining credit.**

That one sentence covers both limits. It is this app's share of the bill,
and the balance lives elsewhere. Nothing on the page says "balance", "spent
so far" or "left". The empty state keeps its current form: "Coding Gym
hasn't used your API key since October 1."

When the month includes rows that can't be priced (only October after the
backfill, or a model without a rate), add a line: "Leaves out N requests
made before Coding Gym recorded costs." The headline then sums only the
priced rows, and that line makes clear the total is partial.

### The projection

- **Method.** Take the own-key cost over a trailing window of whole weeks,
  ending today in the user's zone, then scale it to 30 days
  (`cost / window_days × 30`). Whole weeks matter because generation runs
  on weekdays only. A window that ends on a Friday after four weekdays
  would overstate the rate by about 40 percent.
- **Window.** The last 28 days. When the first priced own-key row is more
  recent than that, use the largest whole number of weeks since then.
- **Honesty rule.** Show no projection until the first priced own-key row
  is at least 14 days old. Two weeks is the shortest window that holds two
  of each weekday. Until then, the line reads: "A monthly estimate appears
  after two weeks of use." If the window cost nothing (generation paused,
  say), hide the line instead of showing $0.
- The projection describes recent pace, not a promise. "At this pace" says
  that, and nothing else needs adding.
- The code lives as `ApiUsage` class methods (`own_key_cost(user, since:)`,
  `projected_monthly_cost(user, today:)`) returning numbers or nil, so no
  new class is needed. A pure-Ruby decision object would also fit the
  "pure decision objects" pattern if those methods outgrow the model.

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
- `docs/decisions/what-a-usage-row-records.md`: add `cost_usd`, priced at
  call time, null meaning unknown.
- `docs/code-notes/app/services/ai_service.md` for `#log_usage`, and
  `docs/file-map.md`.
- `_key_guide.html.erb`'s stale comment (in PR 1).

### Snapshots

- `account.html` changes: the section's markup and copy, and the
  account page's own `<style>` block.
- All six page snapshots (`account`, `dashboard_submitted`,
  `dashboard_swapped_pair`, `dashboard_unsubmitted`, `history`, `setup`)
  change by one CSS line, because the layout's chevron selector list is
  inlined into every page. Nothing else about those five pages changes.
- No prompt snapshot (`prompt_snapshots`, `family_prompt_snapshots`,
  `duck_prompt_snapshots`) and no request snapshot changes. Neither PR
  touches a prompt or a request body.
- The snapshot user has no usage rows, so `account.html` covers only the
  empty state. The populated view, the projection's 14-day rule, the
  "less than $0.01" string and the unpriced-rows line get request specs in
  `spec/requests/accounts_spec.rb`, next to the existing table spec.
