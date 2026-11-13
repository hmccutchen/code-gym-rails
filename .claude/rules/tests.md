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
re-run the failures the summary lists instead. CI runs the unit suite in one
process, and splits the system specs into four groups, one runner each.

`BCrypt::Engine.cost` is set to its minimum for the whole suite
(`spec/support/bcrypt_cost.rb`). At the default cost every `login_as` spent
about half a second hashing, which was most of the suite's runtime.

A spec under `spec/migrations/` migrates inside the example's transaction, so
the rollback puts the schema back. A column that a spec drops and re-adds
lands last until then, and a `SELECT *` plan the connection prepares in that
window no longer matches the restored table. A later file reading the same
table then fails with `cached plan must not change result type` (#758).
`spec/support/migration_plan_reset.rb` clears the connection's prepared
statements after every example in that folder. The hook matches on the
folder, so a migration spec added later is covered without opting in.

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
The pull-refresh note's `sessionStorage` key is reached the same way
(`leave_pull_note`, `pull_note_absent_js`, `pull_note_key_js`), read from
`code_gym_bootstrap.js` (#527).
A system spec that makes one path's request fail, go unanswered or come back
signed out uses `FetchStubHelper` (`stub_fetch`, `fail_requests_to`,
`drop_requests_to`, `redirect_requests_to_login`, `break_the_network`), which
passes every other request to the real fetch, instead of building its own
`window.fetch` replacement for that (#514). A stub that holds a reply, counts
calls or matches on the request body keeps its own.
`spec/conventions/system_spec_waits_spec.rb` fails on the hand-written waits,
the draft key, the pull-refresh note key, a one-expression path stub, a
whole-network rejection and a hand-built redirected reply.
A system spec that clicks inside an animated sheet or dialog emulates reduced
motion first (`emulate_media(reducedMotion: "reduce")`), since a click can press
on one row and release on another while it slides;
`docs/code-notes/spec/system/daily_kind_swap_spec.md` has the details.

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
The `system_test` job is a matrix of four runners. Each runs one group
(`parallel_rspec -n 4 --group-by filesize --only-group N spec/system`) in a
single process against one database, so no runner shares a CPU between two
Chromiums. `-n` comes from the matrix's length, so the two can't disagree and
leave a group unrun. To reproduce a group's failure locally, run that same
command with its group number. The files are grouped by size, so adding a
spec file can move others between groups.

`spec/support/roll_defaults.rb` pins three of `DailyPlan`'s rolls for every
example, since each changes what the plan or ingest produce:

- **The real-source sub-roll** lands `:toy`. Without it, every example
  asserting on a delivered set is nondeterministic at the roll's weight. A
  spec that exercises the grounded `code_review` path opts out with its own
  `:real` stub.
- **The mode roll never lands `bug_hunt`.** A weekend day's one-entry
  `WEEKEND_CODE_REVIEW_MODE_WEIGHTS` roll is turned into a weekday roll, so a
  spec behaves the same on whatever day CI runs it. A `bug_hunt` day changes
  main-track capacity, and ingest refuses the canned `code_review` section,
  which has no `purpose`. A spec that needs `bug_hunt`, or any other
  particular mode, calls `pin_code_review_mode`
  (`spec/support/code_review_mode_helpers.rb`), which stubs both the weekday
  and weekend mode tables. A catch-all `pick` stub hides this pin, so a spec
  with one pins the mode itself through the helper.
- **The files roll lands `:single`.** At `multi: 0.25` a day could otherwise
  ask for files, and a spec's canned single-file `code_review` reply would be
  refused.
  A spec that drives the multi-file shape stubs `:multi` itself. The pin
  lives here, after the catch-all `and_call_original`, because a later
  catch-all hides every pin made before it.

A `WeightedRoll.pick` stub without `with(...)` matches every roll, so it
replaces all three pins without failing.

CI runs the suite against Postgres 18, the major version production runs, on every PR (see `.github/workflows/ci.yml`).

Every CI job pins `runs-on: ubuntu-24.04` rather than `ubuntu-latest`, and `spec/conventions/repo_files_spec.rb` fails on any other value. When `ubuntu-latest` moved to Ubuntu 26.04 on 2026-10-24, `ruby/setup-ruby` had no build of the Ruby in `.ruby-version` (3.3.6) for it, and every job failed at "Set up Ruby". Move the runner when the Ruby version moves, and check that `setup-ruby` has that version for the new image.

How to select focused local coverage, including the shared authorities and
their downstream consumers, is stated in
`.github/copilot-instructions.md` under "Reviewing the pull request itself".
CLAUDE.md owns the final-commit CI and merge policy.
