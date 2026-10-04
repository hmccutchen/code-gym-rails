# Code Gym

Code Gym gives each engineer on the team a short, personalized set of coding
exercises every weekday morning. The exercises are written by an AI model,
using each person's own API key, and they adapt to how that person has done on
earlier sets. A concept you keep finding hard comes back until it sticks, and
the set grows or shrinks with how much you actually finish.

It is an internal team tool, not a public product. See
[`CONTEXT.md`](CONTEXT.md) for why it exists and who it is for.

## How a day works

1. **Log in** with a 6-digit code sent to your email. There are no passwords.
2. **Add an API key** for Anthropic (Claude), Google Gemini or OpenAI on the
   Setup page. Your key is stored encrypted and is only used for your own
   exercises, so each person pays for their own usage.
3. **Get your set.** At 8am on weekdays, in your own time zone, the app
   generates 2 to 4 sections for you. A second AI pass then checks each section
   and rewrites or replaces any that are unclear or unfair.
4. **Answer and rate.** Work through the sections, and rate how hard each one
   felt. A "rubber duck" thinking partner can help you talk through a problem
   without giving away the answer.
5. **Submit for review.** Submitting sends your answers for an AI review, which
   appears on the dashboard. Your answers, ratings and review shape the next
   day's set.

Every set includes a **Code Review** and a **Design Comparison**. The rest of
the day is filled from a rotating pool:

- Pattern of the Month
- Coding Challenge, Architecture Decision, Security Review, Parsons Problem
- Plan Review, Ambiguity Hunt, Pseudocode to Code

Exercises are in Ruby on Rails, JavaScript, or a mix of the two, depending on
your setting.

### Other pages

- **Learn**: a library of every concept the exercises can cover, each with a
  plain-language explanation, a worked example and common pitfalls.
- **Progress**: which difficulty level (junior, senior, principal engineer) you
  currently hold for each concept, based on your reviewed answers.
- **History**: every submitted day, with its problems, answers and review.
- **Setup**: your API keys, language, skill level, how many sections you want
  each day, which kinds of sections you see more or less of, and display
  options such as theme and text size.
- **Account**: optional push reminders, pausing daily generation, logging out
  and deleting your account.

The app also installs to a phone's home screen and can send a reminder when
the day's set is ready.

## Tech stack

- Ruby 3.3.6 and Rails 8.1
- PostgreSQL 16
- Solid Queue for background jobs and the hourly schedule (no Redis needed)
- Faraday for calls to the Anthropic, Gemini and OpenAI APIs
- Active Record Encryption for stored API keys
- Resend for email in production
- RSpec, with Capybara and Playwright for browser tests
- Hosted on [Railway](https://railway.com)

## Running it locally

You need Ruby 3.3.6 and a running PostgreSQL server.

```bash
git clone https://github.com/hmccutchen/code-gym-rails.git
cd code-gym-rails
bundle install
bin/rails db:prepare   # creates the database and loads the schema
bin/dev                # starts the web server at http://localhost:3000
```

No environment variables are needed for development:

- **Login codes** open in your browser instead of being emailed
  (`letter_opener`).
- **Encryption keys** for stored API keys are derived automatically from the
  development secret.
- **Exercise generation** runs when you open the dashboard on a weekday, so
  you don't need the scheduler to try it. On a weekend, use the "generate
  anyway" button.

To generate exercises you need a real API key from one of the supported
providers, added on the Setup page.

## Running the tests

```bash
# Everything except the browser tests
bundle exec rspec --exclude-pattern "system/**/*_spec.rb"

# Browser tests (needs a one-time Playwright install; see the comment at the
# top of spec/support/system_test_helper.rb)
bundle exec rspec spec/system

# Lint
bin/rubocop
```

The tests never call a real AI provider. They use `FakeService`, which returns
canned responses, so they cost nothing to run.

CI runs the full suite, RuboCop, Brakeman and an importmap audit on every pull
request.

## Deployment

Production runs on Railway as three services: web, worker and PostgreSQL.
Each deploy runs database migrations before the new version takes traffic.
Every pull request also gets its own preview app with demo data.

Setup guides:

- [Email delivery with Resend](docs/deploy/railway-smtp-setup.md)
- [Push reminders](docs/deploy/web-push-setup.md)

## Contributing

Work happens on a branch and goes through a pull request into `main`.

- [`CLAUDE.md`](CLAUDE.md) is the engineering reference: architecture, models,
  design decisions, code style and the rules reviews check for.
- [`CONTEXT.md`](CONTEXT.md) explains the product's purpose and non-goals.
