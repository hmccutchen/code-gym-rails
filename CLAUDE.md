# Code Gym Rails — Project Context for Claude Code

## What This Is

A team Rails app for daily personalized coding exercises. Each engineer logs in (magic link, no passwords), adds their own AI provider API key (Anthropic or Gemini), and gets an AI-generated problem set each morning tailored to their performance history. After submitting answers they can request an inline AI review, rate difficulty, and leave feedback — all of which feeds into the next day's problem generation.

## Code Style

Code should be self-documenting. Don't add comments unless they're strictly needed — e.g. to explain a non-obvious *why* (a hidden constraint, a workaround, a subtle invariant). Never add comments that just restate *what* the code does.

## Stack

- **Rails 8.0.5** + PostgreSQL
- **Solid Queue** — background jobs + recurring 8am weekday cron (no Redis needed)
- **Solid Cable / ActionCable** — mounted but unused; the dashboard learns generation is done by polling `GET /dashboard/status`, since this app's layout never loads Turbo JS
- **Faraday** — provider API calls (not the official SDKs)
- **BCrypt** — magic link token digests
- **ActiveRecord Encryption** — encrypts each user's provider API key at rest
- **Railway** — hosting (web + worker services, postgres service)
- **Nixpacks** — auto-detected build from `railway.toml`

## Architecture

```
User logs in (magic link email)
  └→ enters their own Anthropic or Gemini API key (stored encrypted per-user;
     the key's prefix determines user.provider)

8am weekdays (Solid Queue cron via config/recurring.yml):
  GenerateDailyExercisesJob
    └→ AiService.for(user) → ClaudeService | GeminiService
         reads: user.recent_performance (last 10 sessions + ratings + feedback + concepts)
         calls: the user's provider with a personalized prompt, in the user's
                chosen language (user.language_for_today)
         saves: DailyExercise { problem_set: jsonb, language } on success, or
         persists last_generation_error(_date) on the user on failure — the
         dashboard learns the outcome by polling GET /dashboard/status and
         reloading (this app loads no Turbo/Stimulus JS, so a live push has
         no subscriber)

User opens dashboard:
  └→ DashboardController#show
       shows today's DailyExercise, or triggers on-demand generation if missing
       (weekdays only; weekends offer a manual "generate anyway" button)
       3 sections: Code Review snippet, Pattern of the Month, Coding Challenge

User interacts:
  └→ ResponsesController#create      → auto-saves answers + difficulty rating +
       feedback text in one debounced fetch (idempotent). The rating renders at
       the end of the problem set and gates the Submit button — a set cannot be
       submitted unrated. Final submit returns to the dashboard.
  └→ ResponsesController#review      → AiService#review_response → ai_review saved,
       then redirects to /history anchored at that day. Synchronous; the button
       disables and relabels while it runs. Still manual/on-demand.
  └→ ResponsesController#email_review→ mails the completed review to the user,
       then returns to the dashboard (where the button lives)
  └→ DailyExercisesController#regenerate → replaces today's set in place (once/day)
  └→ HistoryController#index         → every submitted session, newest first —
       the single destination for viewing any day's problems, answers, and
       review, today's included. There is no per-day review page.
       (feedback + concept tags are included in tomorrow's generation prompt)
  └→ AccountsController#show/destroy  → log out, or permanently delete (anonymize)
       the account in place while preserving all exercise/response/usage history
```

## Models

| Model             | Key fields                                                                                                |
| ----------------- | --------------------------------------------------------------------------------------------------------- |
| `User`          | email, name, skill_level, focus_areas (jsonb), api_key (encrypted), provider, language, anonymized_at (nullable — set on self-service deletion) |
| `DailyExercise` | user_id, date, problem_set (jsonb: code_review, pattern, challenge), language, generated_at, regenerated_at |
| `DailyResponse` | user_id, daily_exercise_id, answers (jsonb), rating enum, feedback_text, ai_review (jsonb), concept_tags (jsonb) |
| `ApiUsage`      | user_id, tokens_in, tokens_out, purpose, date                                                             |

## Key Design Decisions

- **Per-user API keys**: Each user provides their own Anthropic or Gemini key. Zero shared cost. The key's prefix (`sk-ant-` vs `AIza`/`AQ.`) selects `user.provider`; `AiService.for(user)` dispatches to the right subclass. Stored encrypted with `encrypts :api_key` (ActiveRecord Encryption) in the `users.api_key` column. The `ACTIVE_RECORD_ENCRYPTION_*` env vars are wired in via `config/initializers/active_record_encryption.rb` (Rails does not read them from ENV on its own); development derives throwaway keys from `secret_key_base` automatically.
- **Provider abstraction**: `AiService` is a template-method base class owning prompts, concept vocabularies, JSON parsing, and usage logging. Subclasses implement only `#call` and `#build_connection`. Adding a provider means adding a subclass, not editing the base.
- **Magic link auth**: No passwords. `User#generate_login_token!` creates a BCrypt digest, emails a token, `User#find_by_login_token` does constant-time compare. Tokens expire in 15 minutes.
- **JSONB problem sets**: `problem_set` column stores `{ code_review: {...}, pattern: {...}, challenge: {...} }`. Accessed via convenience methods on `DailyExercise`.
- **Closed concept vocabulary**: each section is tagged with one concept from a fixed per-language list (`AiService::RAILS_CONCEPTS` / `JS_CONCEPTS`); anything a provider invents is normalized to `"other"` so concept history stays aggregatable.
- **Personalization loop**: `user.recent_performance(limit: 10)` returns the last 10 sessions with dates, sections answered, ratings, concept tags, and feedback text. This is embedded verbatim in the generation prompt so each day's exercises adjust to the user's trajectory.
- **One "answered" rule**: a section counts as answered when its trimmed text exceeds 10 characters. `DailyResponse#answered_sections` is the single source of truth — the progress bar, history, and the generation prompt all derive from it.
- **One finish action**: the difficulty rating lives at the end of the problem set and autosaves on click, which enables the Submit button — disabled, with a visible nudge, until a rating exists. Answers and rating land in one `ResponsesController#create` call. The AI review stays a separate, manual step afterward — cost-conscious by design. A rating is set-only: `#create` assigns it only on a valid enum value, so a stale autosave can never clear one. The dashboard requires JavaScript; rating, autosave, progress, and submit are all driven by the inline script, and there is no server-side rejection of an unrated submit because the UI cannot produce one.
- **Idempotent saves**: `ResponsesController#create` uses `find_or_initialize_by(daily_exercise:, date:)` so auto-saves never create duplicates.
- **Preview apps**: a Railway PR environment starts with an empty database, so `PreviewSeed` (`app/services/preview_seed.rb`) seeds three days of demo content for the single account named by `PREVIEW_SEED_EMAIL`. It runs from `preDeployCommand` in every environment including production, and is safe there because it no-ops without that variable, only ever creates rows (never updates or deletes), and never reassigns a non-blank attribute. `PreviewMail` additionally sends mail inline when the variable is set, so magic-link login does not depend on the worker service. **`PREVIEW_SEED_EMAIL` must be set on the PR-environment template only** — set at the shared or base level, Railway propagates it into production. There is no login bypass: PR apps authenticate with real magic links.

## Railway Deployment

- Project: `zesty-enthusiasm` (ID: `5b53ac62-bdb2-4e8d-a7f2-7a457b06ba4e`)
- Web service: `web-production-246e40.up.railway.app`
- Services: web, worker, postgres
- Web start command: `bundle exec puma -C config/puma.rb` (set in `railway.toml`; don't use `rails server -p $PORT` — Railway start commands run in exec form, so `$PORT` is never shell-expanded, while puma reads `PORT` from ENV)
- Worker start command: `bundle exec rake solid_queue:start` (set in `railway.worker.toml`; the worker service's Settings → Config-as-code file path must point at `/railway.worker.toml`, otherwise it inherits the web config and fails healthchecks)
- Env vars already set in Railway: `RAILS_ENV`, `RAILS_MASTER_KEY`, all three `ACTIVE_RECORD_ENCRYPTION_*` keys, `DATABASE_URL` (references postgres service)

## What Still Needs Work
1. ~~Email (magic links won't work yet)~~ — production delivers via Resend's HTTP API (`delivery_method = :resend`; Railway blocks SMTP below Pro). Needs `RESEND_API_KEY`, `MAIL_FROM`, `APP_HOST` on both Railway services: see `docs/deploy/railway-smtp-setup.md`. Sending to teammates requires a verified domain in Resend.
2. ~~`config/environments/production.rb`~~ — done. Resend delivery, `default_url_options`, and `raise_delivery_errors` are wired up from `ENV`.
3. ~~`db:migrate` on Railway~~ — done. `railway.toml` now runs `bundle exec rails db:migrate` via `preDeployCommand` on every deploy, before the new version takes traffic.
4. **Seed a first user**: After deploy, run `rails console` on Railway and create the first user manually, then invite teammates.
5. ~~Remove `/test_login` after buying a domain~~ — done. The route, `SessionsController#test_login`, and `spec/requests/test_login_spec.rb` have been deleted; the `TEST_LOGIN_SECRET` env var can be unset on Railway if still present.

## Local Development

```bash
cp .env.example .env
# fill in DATABASE_URL, SECRET_KEY_BASE, and the ACTIVE_RECORD_ENCRYPTION_* keys
bundle install
rails db:create db:migrate
bin/dev  # starts web + solid_queue worker
```

In development, magic link emails open in the browser via `letter_opener` gem (no SMTP needed).

## Tests

RSpec (`spec/` — models, requests, services, jobs, mailers). Run with:

```bash
bundle exec rspec
```

CI runs the suite against postgres 16 on every PR (see `.github/workflows/ci.yml`).

## File Map

- `app/services/ai_service.rb` — provider-agnostic base: prompts, concept vocabularies, JSON parsing, usage logging
- `app/services/claude_service.rb` / `gemini_service.rb` — per-provider HTTP call + connection only
- `app/jobs/generate_daily_exercises_job.rb` — morning batch job + on-demand generation; persists failure state for the dashboard's status-polling to observe
- `app/controllers/responses_controller.rb` — auto-save (answers + rating), review, email-review endpoints
- `app/views/responses/_answered_sections.html.erb` — read-only render of a submitted day; shared by the dashboard's submitted state and every history entry. Its styles live in the layout's `<style>`, not a per-page block, precisely because it renders on both.
- `app/controllers/daily_exercises_controller.rb` — manual generate + once-daily regenerate
- `app/controllers/sessions_controller.rb` — magic link create + verify
- `app/controllers/accounts_controller.rb` — Account page: log out + self-service deletion (anonymizes the user row in place)
- `app/models/user.rb` — auth methods, `recent_performance`, `language_for_today`, `anonymize!` / `active` scope, encryption
- `app/services/preview_seed.rb` — demo content for PR apps; create-only, gated on `PREVIEW_SEED_EMAIL`
- `app/services/preview_mail.rb` — inline mail delivery in preview apps, so login never needs a worker
- `config/recurring.yml` — Solid Queue cron schedule (8am UTC weekdays)
- `railway.toml` — build + deploy config for Railway
