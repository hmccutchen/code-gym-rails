---
paths:
  - "spec/**"
  - ".github/workflows/**"
  - ".rspec"
  - "Gemfile"
---

# Tests

RSpec (`spec/` — models, requests, services, jobs, mailers). Run with:

```bash
bundle exec rspec
```

CLAUDE.md says what to run when.

**Parallel runs.** `parallel_tests` splits the suite across processes, each
with its own test database (`code_gym_rails_test`, `code_gym_rails_test2`,
...; see the test section of `config/database.yml`). One-time setup, and again
after a migration:

```bash
RAILS_ENV=test bin/rails "parallel:create[4]" "parallel:prepare[4]"
bundle exec parallel_rspec -n 4 --exclude-pattern "^spec/system/" spec
bundle exec parallel_rspec -n 2 spec/system
```

Two processes for system specs, not four: each starts its own Chromium, and
the fetch-driven specs wait on real timing, so a crowded CPU makes them the
first to flake. Each process keeps its own `spec/examples<N>.txt`, so
`--only-failures` after a parallel run only sees the first process's results;
re-run the failures the summary lists instead. CI runs serially.

`BCrypt::Engine.cost` is set to its minimum for the whole suite
(`spec/support/bcrypt_cost.rb`). At the default cost every `login_as` spent
about half a second hashing, which was most of the suite's runtime.

`spec/system/` holds a small number of real-browser specs (Capybara +
capybara-playwright-driver) covering flows unit/request specs can't fully
verify — rating-gated submit, review loading state — driven exclusively
against a `FakeService` (`provider: "fake"`) test user, never a real API key.
`FakeService` returns every section kind at once rather than the two to four
a real provider is asked for, so system specs can't assert which third
`DailyPlan` chose — cover that in service/job specs instead.
`FakeService` picks each reply by the request's purpose from its `REPLIES`
table, and raises on a purpose with no entry. It answers `judge_section` with
a canned `keep` verdict (plus a matching `better` for a kind the judge solves
blind), so the judged path runs end to end in specs without a rejection
unless an example stubs `judge_section` itself.
A spec that stubs a provider's HTTP and uses the fake as its reply oracle has
only the posted body, so it gets the purpose from the system prompt with
`purpose_for` (`spec/support/fake_replies.rb`), whose marker table maps each
purpose to a phrase its system prompt carries. Provider specs send a request
through `call_provider` (`spec/support/provider_call_helpers.rb`), which
builds it with `AiService::Request.build` and its defaults.

A system spec waits through Capybara's matchers or `wait_for`
(`spec/support/system_test_helper.rb`), never a hand-written `sleep ... until`
loop or `Timeout.timeout`, and passes no `wait:` beyond a deliberately short
negative check: every wait follows `Capybara.default_max_wait_time`, and
`wait_for` raises on timeout instead of returning silently (#456).
A system spec reaches the answer draft copy through `JavascriptReadyHelper`
(`draft_key_js`, `stored_draft_js`, `wait_for_draft_cleared`,
`wait_for_answers_settled`), which reads the key from `draft_store.js`, never
by writing the key or a string-keyed `localStorage` call itself (#501).
A system spec that makes one path's request fail, go unanswered or come back
signed out uses `FetchStubHelper` (`stub_fetch`, `fail_requests_to`,
`drop_requests_to`, `redirect_requests_to_login`, `break_the_network`), which
passes every other request to the real fetch, instead of building its own
`window.fetch` replacement for that (#514). A stub that holds a reply, counts
calls or matches on the request body keeps its own.
`spec/conventions/system_spec_waits_spec.rb` fails on the hand-written waits,
the draft key, a one-expression path stub, a whole-network rejection and a
hand-built redirected reply.

A system spec that needs today's set calls `visit_with_todays_set(user)`,
which generates it before the first page load, since visiting first would wait
out the dashboard's 3-second "generating" poll, and returns only once every
controller on the page has connected (`wait_for_js`). `dashboard_generation_spec.rb` is
the one spec that goes through that poll on purpose.
Running them locally requires a one-time install of the pinned Playwright CLI
and a Chromium build, the same commands CI runs:

```bash
npm --prefix spec/playwright ci
./spec/playwright/node_modules/.bin/playwright-core install --with-deps chromium
```

`npm ci` rather than `npm install`, so setup never rewrites the lockfile. The
CLI version must match what playwright-ruby-client expects, so bump it
together with the gem:

```bash
npm --prefix spec/playwright install --save-exact \
  "playwright-core@$(bundle exec ruby -e 'require "playwright/version"; puts Playwright::COMPATIBLE_PLAYWRIGHT_VERSION')"
```

The npm manifests live in `spec/playwright/`, not the repo
root, so Nixpacks doesn't add a Node phase to the Railway production build.
CI runs system specs in a separate `system_test` job that installs the same
CLI (cached on `spec/playwright/package-lock.json`), while the `test` job runs
everything else via `--exclude-pattern "system/**/*_spec.rb"` — the two halves
run in parallel so unit/request feedback isn't gated behind browser setup.

`spec/support/real_source_default.rb` pins `DailyPlan`'s real-source sub-roll
to `:toy` for every example; a spec that exercises the grounded `code_review`
path opts out with its own `:real` stub. The mode roll is deliberately *not*
pinned this way — it only changes the prompt, so a canned response comes back
through ingest identical either way — but the real-source roll changes what
ingest stamps onto the set, and without the default every example asserting
on a delivered set is nondeterministic at the roll's weight. A spec that needs
a particular mode calls `pin_code_review_mode` (`spec/support/code_review_mode_helpers.rb`),
which stubs only the mode's weights. A `WeightedRoll.pick` stub without
`with(...)` matches every roll, so it replaces the `:toy` pin without failing.

CI runs the suite against Postgres 18, the major version production runs, on every PR (see `.github/workflows/ci.yml`).

Every CI job pins `runs-on: ubuntu-24.04` rather than `ubuntu-latest`. When `ubuntu-latest` moved to Ubuntu 26.04 on 2026-10-24, `ruby/setup-ruby` had no build of the Ruby in `.ruby-version` (3.3.6) for it, and every job failed at "Set up Ruby". Move the runner when the Ruby version moves, and check that `setup-ruby` has that version for the new image.

When a scoped run is enough and when it isn't — the shared authorities that
always pull in the full suite — is stated once, in
`.github/copilot-instructions.md` under "Reviewing the pull request itself".
