# Code Gym

Code Gym gives each engineer on a team a short set of coding exercises every
weekday morning, written by an AI model from that person's own history. You
answer, rate how hard each one felt, and get a graded review, and the next
day's set goes back to what you missed. Most exercises train the judgment the
job runs on, like reviewing code, comparing two designs or questioning a vague
spec, and each engineer runs it on their own AI provider key.

It was built for one Rails team's junior and newer engineers, as daily practice
alongside pairing and code review rather than a replacement for them. It is not
a general practice product: there's no billing or multi-team setup, and the
exercises stay with Ruby on Rails and JavaScript.

- **Ten kinds of exercise.** Code review, design comparison, security review,
  architecture decisions, coding challenges, Parsons problems (put shuffled
  lines back in order), plan review, ambiguity hunts, pseudocode to code, and
  a pattern of the month.
- **Short days.** A set has 2 to 4 sections. It grows as you finish more of
  your recent sets and do well on them, and shrinks when you don't.
- **Weak spots come back.** A concept you keep struggling with shows up again
  until it sticks. Once you've got it, a retention check returns after 7 days,
  and the gap doubles each time up to 60.
- **Checked before you see it.** A second AI pass judges every drafted section
  and can fix its wording or throw it out and have it rewritten.
- **Graded on a fixed rubric.** Each answer is rated beginner, developing,
  solid or strong, against the level the section was written for.
- **Levels per kind.** Junior, mid-level, senior or principal engineer, set
  for each kind of exercise. The app suggests a step up or back from your
  results, and you can turn that off.
- **Your own key.** Anthropic, Google Gemini or OpenAI. Your account page
  shows this month's requests and tokens per provider.
- **Works on a phone.** Add it to your home screen, get a push reminder when
  your set is ready, and keep a draft answer if the connection drops.

Here is a code review exercise, the sample the test suite uses:

> **Code Review.** This method recalculates a customer's loyalty tier every
> time it's called, even inside a loop over the whole customer list. What's
> the issue and how would you fix it?

```ruby
def loyalty_tier(customer)
  total = customer.orders.sum(&:total_cents)
  case total
  when 0...10_000 then "bronze"
  when 10_000...50_000 then "silver"
  else "gold"
  end
end

customers.each { |c| puts loyalty_tier(c) }
```

[`CONTEXT.md`](CONTEXT.md) explains why the app exists and what it is not
meant to do.

**Contents:** [Using it](#using-it) ·
[Running it locally](#running-it-locally) ·
[Contributing](#contributing) · [Deploying](#deploying)

---

## Using it

The team's instance is at https://web-production-246e40.up.railway.app.

1. Sign in with your email. You'll get a 6-digit code; there are no passwords.
   Your first sign-in creates your account.
2. On the Setup page, add an API key from one of these providers. The app uses
   your own key, so you pay only for your own exercises.
   - Anthropic: https://console.anthropic.com/settings/keys
   - Google Gemini: https://aistudio.google.com/apikey
   - OpenAI: https://platform.openai.com/api-keys
3. Choose your language (Ruby on Rails, JavaScript, or both on alternate days)
   and your level on the same page. Everything else there can wait.

Your set is ready at 8am on weekdays, in your time zone. If you open the
dashboard before then, it generates one on the spot.

If something is broken or confusing, open an issue or tell
[@hmccutchen](https://github.com/hmccutchen).

---

## Running it locally

You need Ruby 3.3.6 (from `.ruby-version`), a local PostgreSQL server and
Node.js. No environment variables are needed.

```bash
bundle install
npm --prefix vendor/prettier ci   # Prettier, which formats generated JavaScript
bin/rails db:prepare              # creates the database and loads the schema
bin/dev                           # web server at http://localhost:3000
bin/jobs                          # optional: background worker and the 8am schedule
```

In development, login codes open in your browser instead of being emailed. To
generate exercises, add a real API key on the Setup page.

Tests use a fake AI provider, so they cost nothing to run:

```bash
bundle exec rspec --exclude-pattern "system/**/*_spec.rb"   # everything but browser tests
bundle exec rspec spec/system                               # browser tests
bin/rubocop
```

The browser tests need Playwright and a Chromium build, installed once:

```bash
npm --prefix spec/playwright ci
./spec/playwright/node_modules/.bin/playwright-core install --with-deps chromium
```

---

## Contributing

Make changes on a branch and open a pull request into `main`. CI runs the
tests, RuboCop and the security scans on every pull request, and each one gets
a preview app with demo data.

[`CLAUDE.md`](CLAUDE.md) is the reference for everything else: code style,
what reviews check for and an outline of the architecture. Each area's design
decisions are in `.claude/rules/`, with the full reasoning in `docs/decisions/`.

---

## Deploying

Production is on Railway, in the `zesty-enthusiasm` project, as three
services: web, worker and PostgreSQL. Each deploy runs migrations before the
new version takes traffic.

- [Email delivery with Resend](docs/deploy/railway-smtp-setup.md)
- [Push reminders](docs/deploy/web-push-setup.md)
