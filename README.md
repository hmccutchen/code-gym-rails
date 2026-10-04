# Code Gym

Our team's daily coding practice. Every weekday morning you get a short set of
exercises written by an AI model and tuned to how you did on earlier sets. You
answer them, rate how hard each one felt, and get an AI review. That review
shapes the next day's set.

[`CONTEXT.md`](CONTEXT.md) explains why it exists and what it is not meant to
do.

## Using it

The app is at https://web-production-246e40.up.railway.app.

1. Sign in with your email. You'll get a 6-digit code; there are no passwords.
   Your first sign-in creates your account.
2. On the Setup page, add an API key from one of these providers. The app uses
   your own key, so you pay only for your own exercises.
   - Anthropic: https://console.anthropic.com/settings/keys
   - Google Gemini: https://aistudio.google.com/apikey
   - OpenAI: https://platform.openai.com/api-keys
3. Choose your language (Rails, JavaScript or both) and skill level on the same
   page. Everything else there can wait.

Your set is ready at 8am on weekdays, in your time zone. If you open the
dashboard before then, it generates one on the spot.

If something is broken or confusing, open an issue or tell
[@hmccutchen](https://github.com/hmccutchen).

## Working on it

You need Ruby 3.3.6 and a local PostgreSQL server. No environment variables
are needed.

```bash
bundle install
bin/rails db:prepare   # creates the database and loads the schema
bin/dev                # web server at http://localhost:3000
bin/jobs               # optional: background worker and the 8am schedule
```

In development, login codes open in your browser instead of being emailed. To
generate exercises, add a real API key on the Setup page.

Tests use a fake AI provider, so they cost nothing to run:

```bash
bundle exec rspec --exclude-pattern "system/**/*_spec.rb"   # everything but browser tests
bundle exec rspec spec/system                               # browser tests
bin/rubocop
```

The browser tests need a one-time Playwright install. The steps are at the top
of `spec/support/system_test_helper.rb`.

Make changes on a branch and open a pull request into `main`. CI runs the
tests, RuboCop and the security scans on every pull request, and each one gets
a preview app with demo data.

[`CLAUDE.md`](CLAUDE.md) is the reference for everything else: architecture,
design decisions, code style and what reviews check for.

## Running it

Production is on Railway, in the `zesty-enthusiasm` project, as three
services: web, worker and PostgreSQL. Each deploy runs migrations before the
new version takes traffic.

- [Email delivery with Resend](docs/deploy/railway-smtp-setup.md)
- [Push reminders](docs/deploy/web-push-setup.md)
