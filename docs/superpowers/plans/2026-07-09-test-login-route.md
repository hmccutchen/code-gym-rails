# Secret-Gated Test Login Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an interim, owner-only `GET /test_login` route gated by a `TEST_LOGIN_SECRET` env var, so the owner can log into production without the magic-link email round-trip until a sending domain is purchased.

**Architecture:** One new action on `SessionsController` (it already skips auth filters and owns session establishment) plus one route. Every failure mode returns a bare 404 so the route is invisible when disabled. Magic-link + Resend delivery are untouched.

**Tech Stack:** Rails 8.0.5, RSpec request specs, `ActiveSupport::SecurityUtils.secure_compare`.

## Global Constraints

- Spec: `docs/superpowers/specs/2026-07-09-test-login-design.md` — follow it exactly.
- Compare secrets with `ActiveSupport::SecurityUtils.secure_compare(params[:secret].to_s, ENV["TEST_LOGIN_SECRET"])` — the `.to_s` guard is required (nil param must not raise before the compare).
- Normalize the email param with `.to_s.strip.downcase` (matches `SessionsController#create`).
- All failure paths (env var unset, wrong/missing secret, unknown email) must be indistinguishable: `head :not_found`, no body differences, no user creation.
- Do not modify the magic-link flow, Resend config, or session duration.
- No live Railway changes inside this plan; setting `TEST_LOGIN_SECRET` on the web service happens after merge (noted in Task 2).

---

### Task 1: `GET /test_login` route + SessionsController#test_login (TDD)

**Files:**
- Test: `spec/requests/test_login_spec.rb` (create)
- Modify: `config/routes.rb` (auth block, after the `auth/verify` route)
- Modify: `app/controllers/sessions_controller.rb` (new action after `verify`)

**Interfaces:**
- Consumes: existing `User.find_by(email:)`, `session[:user_id]` convention from `SessionsController#verify`.
- Produces: `test_login_path` route helper; `GET /test_login?secret=&email=` endpoint. Nothing later depends on it (Task 2 is docs only).

- [ ] **Step 1: Write the failing request specs**

Create `spec/requests/test_login_spec.rb`:

```ruby
require "rails_helper"

RSpec.describe "Test login", type: :request do
  let!(:user) { User.create!(email: "dev@example.com", name: "Dev") }

  def with_test_login_secret(value)
    previous = ENV["TEST_LOGIN_SECRET"]
    ENV["TEST_LOGIN_SECRET"] = value
    yield
  ensure
    ENV["TEST_LOGIN_SECRET"] = previous
  end

  context "when TEST_LOGIN_SECRET is set" do
    it "logs in the matching user with the correct secret" do
      with_test_login_secret("s3kr1t") do
        get test_login_path(secret: "s3kr1t", email: " Dev@Example.com ")

        expect(response).to redirect_to(root_path)
        expect(session[:user_id]).to eq(user.id)
      end
    end

    it "returns 404 for a wrong secret and does not log in" do
      with_test_login_secret("s3kr1t") do
        get test_login_path(secret: "wrong", email: "dev@example.com")

        expect(response).to have_http_status(:not_found)
        expect(session[:user_id]).to be_nil
      end
    end

    it "returns 404 with no secret param at all" do
      with_test_login_secret("s3kr1t") do
        get test_login_path(email: "dev@example.com")

        expect(response).to have_http_status(:not_found)
        expect(session[:user_id]).to be_nil
      end
    end

    it "returns 404 for an unknown email and creates no user" do
      with_test_login_secret("s3kr1t") do
        expect {
          get test_login_path(secret: "s3kr1t", email: "ghost@example.com")
        }.not_to change(User, :count)

        expect(response).to have_http_status(:not_found)
        expect(session[:user_id]).to be_nil
      end
    end
  end

  context "when TEST_LOGIN_SECRET is unset" do
    it "returns 404 even with a matching-looking secret" do
      with_test_login_secret(nil) do
        get test_login_path(secret: "anything", email: "dev@example.com")

        expect(response).to have_http_status(:not_found)
        expect(session[:user_id]).to be_nil
      end
    end
  end
end
```

- [ ] **Step 2: Run the specs to verify they fail**

Run: `bundle exec rspec spec/requests/test_login_spec.rb`
Expected: all 5 examples FAIL with `NoMethodError: undefined method 'test_login_path'` (route doesn't exist yet).

- [ ] **Step 3: Add the route**

In `config/routes.rb`, after the `get  "auth/verify", ...` line, add:

```ruby
  # Interim owner-only login bypass (active only when TEST_LOGIN_SECRET is set).
  # Remove after a sending domain is verified -- see docs/superpowers/specs/2026-07-09-test-login-design.md
  get "test_login", to: "sessions#test_login"
```

- [ ] **Step 4: Add the action**

In `app/controllers/sessions_controller.rb`, after the `verify` action, add:

```ruby
  # GET /test_login?secret=...&email=...
  # Interim owner-only bypass while magic-link email requires a verified
  # sending domain. Gated by the TEST_LOGIN_SECRET env var; every failure
  # mode is an identical bare 404 so the route is invisible when disabled
  # and reveals nothing when probed.
  def test_login
    configured = ENV["TEST_LOGIN_SECRET"]
    return head :not_found if configured.blank?
    return head :not_found unless ActiveSupport::SecurityUtils.secure_compare(params[:secret].to_s, configured)

    user = User.find_by(email: params[:email].to_s.strip.downcase)
    return head :not_found if user.nil?

    session[:user_id] = user.id
    redirect_to root_path, notice: "Logged in as #{user.name} (test login)."
  end
```

- [ ] **Step 5: Run the specs to verify they pass**

Run: `bundle exec rspec spec/requests/test_login_spec.rb`
Expected: 5 examples, 0 failures.

- [ ] **Step 6: Run the full suite and lint**

Run: `bundle exec rspec && bundle exec rubocop`
Expected: all examples pass (27 total: 22 existing + 5 new), no rubocop offenses.

- [ ] **Step 7: Commit**

```bash
git add spec/requests/test_login_spec.rb config/routes.rb app/controllers/sessions_controller.rb
git commit -m "Add secret-gated /test_login bypass route (interim until domain)"
```

---

### Task 2: Removal checklist in CLAUDE.md

**Files:**
- Modify: `CLAUDE.md` ("What Still Needs Work" section)

**Interfaces:**
- Consumes: nothing from Task 1 (docs only).
- Produces: nothing — final task.

- [ ] **Step 1: Add the removal item**

In `CLAUDE.md`, in the "What Still Needs Work" numbered list, append as a new item after the existing final item:

```markdown
5. **Remove `/test_login` after buying a domain**: once a sending domain is verified in Resend and `MAIL_FROM` is updated, unset `TEST_LOGIN_SECRET` on the Railway web service (instantly disables the route) and delete the route, `SessionsController#test_login`, and `spec/requests/test_login_spec.rb`.
```

- [ ] **Step 2: Verify the diff**

Run: `git diff CLAUDE.md`
Expected: only the new item 5 added; items 1-4 untouched.

- [ ] **Step 3: Commit**

```bash
git add CLAUDE.md
git commit -m "Note /test_login removal checklist in CLAUDE.md"
```

---

## After the plan (outside execution)

Post-merge, on the Railway **web** service only: generate the secret with `openssl rand -hex 24` and set it via `railway variable set -s web -e production TEST_LOGIN_SECRET=<value>`; then the bookmarkable login URL is `https://web-production-246e40.up.railway.app/test_login?secret=<value>&email=mccutchen.hassan@gmail.com`.
