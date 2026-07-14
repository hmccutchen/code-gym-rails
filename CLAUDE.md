# Code Gym Rails — Project Context for Claude Code

## What This Is

A team Rails app for daily personalized coding exercises. Each engineer logs in (magic link, no passwords), adds their own AI provider API key (Anthropic or Gemini), and gets an AI-generated problem set each morning tailored to their performance history. After submitting answers they can request an inline AI review, rate difficulty, and leave feedback — all of which feeds into the next day's problem generation.

## Stack

- **Rails 8.0.5** + PostgreSQL
- **Solid Queue** — background jobs + recurring 8am weekday cron (no Redis needed)
- **Turbo Streams** over Solid Cable — live dashboard updates when generation finishes
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
         saves: DailyExercise { problem_set: jsonb, language }
         broadcasts: Turbo Stream replace of #dashboard-content (success or failure)

User opens dashboard:
  └→ DashboardController#show
       shows today's DailyExercise, or triggers on-demand generation if missing
       (weekdays only; weekends offer a manual "generate anyway" button)
       3 sections: Code Review snippet, Pattern of the Month, Coding Challenge

User interacts:
  └→ ResponsesController#create      → auto-save answers (debounced fetch, idempotent)
  └→ ResponsesController#review      → AiService#review_response → ai_review saved
  └→ ResponsesController#feedback    → saves rating (too_easy/right_level/too_hard) + text
  └→ ResponsesController#email_review→ mails the completed review to the user
  └→ DailyExercisesController#regenerate → replaces today's set in place (once/day)
  └→ HistoryController#index         → past submitted sessions
       (feedback + concept tags are included in tomorrow's generation prompt)
```

## Models

| Model             | Key fields                                                                                                |
| ----------------- | --------------------------------------------------------------------------------------------------------- |
| `User`          | email, name, skill_level, focus_areas (jsonb), api_key (encrypted), provider, language                     |
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
- **Idempotent saves**: `ResponsesController#create` uses `find_or_initialize_by(daily_exercise:, date:)` so auto-saves never create duplicates.

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
5. **Remove `/test_login` after buying a domain**: once a sending domain is verified in Resend and `MAIL_FROM` is updated, unset `TEST_LOGIN_SECRET` on the Railway web service (instantly disables the route) and delete the route, `SessionsController#test_login`, and `spec/requests/test_login_spec.rb`.

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
- `app/jobs/generate_daily_exercises_job.rb` — morning batch job + on-demand generation + Turbo broadcasts
- `app/controllers/responses_controller.rb` — auto-save, review, feedback, email-review endpoints
- `app/controllers/daily_exercises_controller.rb` — manual generate + once-daily regenerate
- `app/controllers/sessions_controller.rb` — magic link create + verify
- `app/models/user.rb` — auth methods, `recent_performance`, `language_for_today`, encryption
- `config/recurring.yml` — Solid Queue cron schedule (8am UTC weekdays)
- `railway.toml` — build + deploy config for Railway
