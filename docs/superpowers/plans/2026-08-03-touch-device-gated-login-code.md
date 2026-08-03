# Touch-Device-Gated Login Code Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show the 6-digit login code — both on the login page and in the magic-link email — only when the login was requested from a touch device, so desktop users never learn the mechanism exists.

**Architecture:** The login form carries a hidden `touch_device` field set by a small inline script. `SessionsController#create` resolves that one signal into two outcomes: whether to pass `raw_login_code` to the mailer, and a `session[:pending_login_touch]` flag that decides whether the pending page renders the code form at all. Deciding server-side means the email and the UI cannot drift apart, and desktop never renders a code field that JavaScript then has to hide.

**Tech Stack:** Rails 8.0.5, RSpec, vanilla inline JS (no Turbo/Stimulus — this app loads none).

**Spec:** `docs/superpowers/specs/2026-08-03-touch-device-gated-login-code-design.md`

## Global Constraints

- "Touch device" means any of: `window.navigator.standalone === true`, `matchMedia("(display-mode: standalone)").matches`, or `matchMedia("(pointer: coarse)").matches`. Never use viewport width or User-Agent sniffing for this decision.
- Absent or unset `touch_device` means desktop. That default is deliberate: a mobile user with JavaScript disabled gets no code but still gets a working magic link.
- `User#generate_login_token!` stays unconditional — the code digest is still generated and stored on every request. Do not thread a presentation flag into the model.
- `touch_device` is not a security boundary. A forged `touch_device=1` only mails that person their own code, which is no weaker than the link already in the same email. Do not add validation or signing around it.
- No change to the code's expiry, lockout, or invalidation rules, and no change to the magic-link flow's security properties.
- No new gems.
- Inline `<script>` tags are this app's established convention for client-side behavior.

---

### Task 1: `SessionsController` — resolve the touch signal into the email and session state

**Files:**
- Modify: `app/controllers/sessions_controller.rb` (`#create`, `#verify`, `#verify_code`)
- Test: `spec/requests/sessions_spec.rb`

**Interfaces:**
- Consumes: `User#raw_login_code` and `UserMailer.magic_link(user, raw_token, raw_code = nil)` (both already exist; `magic_link.text.erb` already guards on `@raw_code.present?`, so passing `nil` omits the code line with no mailer change).
- Produces: `session[:pending_login_touch]` (boolean, set in `#create`, deleted in `#verify` and `#verify_code`) — consumed by Task 2's `_pending.html.erb`.

- [ ] **Step 1: Update the existing `POST /login/code` specs to request as a touch device**

These specs establish a pending login and then scrape the code out of the delivered email. Once Task 1 gates the code on `touch_device`, the first one below cannot find a code without it. Add `touch_device: "1"` to all three `post login_path` calls inside `describe "POST /login/code"` in `spec/requests/sessions_spec.rb`, so they continue to exercise the real touch-device flow.

This is not a weakening of any assertion — every existing expectation about login, lockout, and invalidation stays exactly as written. Only the request now says which kind of device made it.

The three calls to change, in order of appearance in that block:

```ruby
        post login_path, params: { email: "dev@example.com", name: "Dev", touch_device: "1" }
```
```ruby
      post login_path, params: { email: "dev@example.com", name: "Dev", touch_device: "1" }
```
```ruby
        post login_path, params: { email: "dev@example.com", name: "Dev", touch_device: "1" }
```

The fourth spec in that block ("returns nil-equivalent (no session) when there is no pending login in this browser") never calls `post login_path` at all — leave it untouched.

- [ ] **Step 2: Write the failing gating specs**

Add this as a new top-level `describe` block in `spec/requests/sessions_spec.rb`, directly after the `describe "POST /login/code"` block:

```ruby
  describe "login code gating by device" do
    include ActiveJob::TestHelper

    it "emails a login code when the request came from a touch device" do
      perform_enqueued_jobs do
        post login_path, params: { email: "dev@example.com", name: "Dev", touch_device: "1" }
      end

      expect(ActionMailer::Base.deliveries.last.body.encoded).to match(/enter this code: \d{6}/)
    end

    it "omits the login code when the request came from a desktop browser" do
      perform_enqueued_jobs do
        post login_path, params: { email: "dev@example.com", name: "Dev" }
      end

      expect(ActionMailer::Base.deliveries.last.body.encoded).not_to include("enter this code")
    end

    it "still emails a working magic link to a desktop browser" do
      perform_enqueued_jobs do
        post login_path, params: { email: "dev@example.com", name: "Dev" }
      end
      raw_token = ActionMailer::Base.deliveries.last.body.encoded[/token=([\w-]+)/, 1]

      get verify_auth_path(token: raw_token)

      expect(response).to redirect_to(root_path)
      expect(session[:user_id]).to be_present
    end

    it "clears the pending-login device flag after a link login" do
      post login_path, params: { email: "dev@example.com", name: "Dev", touch_device: "1" }
      raw_token = User.find_by(email: "dev@example.com").generate_login_token!

      get verify_auth_path(token: raw_token)

      expect(session[:pending_login_email]).to be_nil
      expect(session[:pending_login_touch]).to be_nil
    end

    it "clears the pending-login device flag after a code login" do
      perform_enqueued_jobs do
        post login_path, params: { email: "dev@example.com", name: "Dev", touch_device: "1" }
      end
      raw_code = ActionMailer::Base.deliveries.last.body.encoded[/enter this code: (\d{6})/, 1]

      post verify_login_code_path, params: { code: raw_code }

      expect(session[:pending_login_email]).to be_nil
      expect(session[:pending_login_touch]).to be_nil
    end
  end
```

- [ ] **Step 3: Run the specs to verify they fail**

Run: `bundle exec rspec spec/requests/sessions_spec.rb -e "login code gating by device"`
Expected: FAIL — "omits the login code when the request came from a desktop browser" fails because the code is currently always emailed, and both "clears the pending-login device flag" specs fail because `session[:pending_login_touch]` is never set or deleted yet.

- [ ] **Step 4: Gate the emailed code on the touch signal**

In `app/controllers/sessions_controller.rb`, replace this comment and method signature line:

```ruby
  # POST /login — send magic link (and its login-code twin)
  def create
    email = params[:email].to_s.strip.downcase
    name  = params[:name].to_s.strip
```

with:

```ruby
  # POST /login — send magic link, plus its login-code twin only when the
  # request came from a touch device. The code is redeemable solely in the
  # browser that requested it (see #verify_code), so mailing one to a desktop
  # requester would be noise they could never act on.
  # See docs/superpowers/specs/2026-08-03-touch-device-gated-login-code-design.md
  def create
    email = params[:email].to_s.strip.downcase
    name  = params[:name].to_s.strip
    touch_device = params[:touch_device] == "1"
```

- [ ] **Step 5: Pass the code conditionally and record the flag**

In the same method, replace:

```ruby
    raw_token = user.generate_login_token!
    UserMailer.magic_link(user, raw_token, user.raw_login_code).deliver_later

    # Drives the "check your email" pending state on the login page (Fix 1's
    # code field, Fix 2's polling) across reloads in this same browser.
    session[:pending_login_email] = email
```

with:

```ruby
    raw_token = user.generate_login_token!
    UserMailer.magic_link(user, raw_token, touch_device ? user.raw_login_code : nil).deliver_later

    # Drives the "check your email" pending state on the login page (the code
    # field, the polling) across reloads in this same browser.
    session[:pending_login_email] = email
    session[:pending_login_touch] = touch_device
```

- [ ] **Step 6: Clear the flag on both success paths**

In `#verify`, replace:

```ruby
    session.delete(:pending_login_email)

    redirect_to session.delete(:return_to) || root_path, notice: "Welcome back, #{user.name}!"
  end
```

with:

```ruby
    session.delete(:pending_login_email)
    session.delete(:pending_login_touch)

    redirect_to session.delete(:return_to) || root_path, notice: "Welcome back, #{user.name}!"
  end
```

In `#verify_code`, replace:

```ruby
      session[:user_id] = user.id
      session.delete(:pending_login_email)
```

with:

```ruby
      session[:user_id] = user.id
      session.delete(:pending_login_email)
      session.delete(:pending_login_touch)
```

- [ ] **Step 7: Run the specs to verify they pass**

Run: `bundle exec rspec spec/requests/sessions_spec.rb`
Expected: PASS — all specs in the file, including the pre-existing `POST /login/code`, `GET /login/status`, and `session lifetime` blocks.

- [ ] **Step 8: Commit**

```bash
git add app/controllers/sessions_controller.rb spec/requests/sessions_spec.rb
git commit -m "Email the login code only for touch-device login requests"
```

---

### Task 2: Views — capture the signal, and render the code form only for touch devices

**Files:**
- Modify: `app/views/sessions/new.html.erb`
- Modify: `app/views/sessions/_pending.html.erb`
- Test: `spec/requests/sessions_spec.rb`

**Interfaces:**
- Consumes: `session[:pending_login_touch]` (Task 1), `verify_login_code_path` and `login_status_path` (existing routes).
- Produces: a `touch_device` form parameter on `POST /login`, which is what Task 1's `#create` reads. Nothing downstream consumes anything from this task.

- [ ] **Step 1: Write the failing view specs**

Add this as a new top-level `describe` block in `spec/requests/sessions_spec.rb`, directly after the `describe "login code gating by device"` block:

```ruby
  describe "the login page's device-gated code UI" do
    it "carries a touch_device field for the client script to set" do
      get login_path

      expect(response.body).to include('name="touch_device"')
    end

    it "offers the code form on the pending page after a touch-device request" do
      post login_path, params: { email: "dev@example.com", name: "Dev", touch_device: "1" }

      get login_path

      expect(response.body).to include("/login/code")
      expect(response.body).to include("6-digit code")
    end

    it "hides the code form on the pending page after a desktop request" do
      post login_path, params: { email: "dev@example.com", name: "Dev" }

      get login_path

      expect(response.body).not_to include("/login/code")
      expect(response.body).to include("Check your email")
    end
  end
```

- [ ] **Step 2: Run the specs to verify they fail**

Run: `bundle exec rspec spec/requests/sessions_spec.rb -e "the login page's device-gated code UI"`
Expected: FAIL — "carries a touch_device field" fails because the form has no such field, and "hides the code form" fails because the pending partial currently renders the code form unconditionally.

- [ ] **Step 3: Add the hidden field and detection script to the login form**

In `app/views/sessions/new.html.erb`, replace:

```erb
    <%= form_with url: login_path, method: :post do |f| %>
      <div class="form-field">
        <%= f.label :name, "Name (first time only)" %>
```

with:

```erb
    <%= form_with url: login_path, method: :post do |f| %>
      <%= f.hidden_field :touch_device, value: "", id: "touch-device" %>
      <div class="form-field">
        <%= f.label :name, "Name (first time only)" %>
```

Then, in the same file, replace the closing of that branch:

```erb
      <%= f.submit "Send magic link →", class: "btn btn-primary", style: "width:100%;padding:.75rem;" %>
    <% end %>
  <% end %>
</div>
```

with:

```erb
      <%= f.submit "Send magic link →", class: "btn btn-primary", style: "width:100%;padding:.75rem;" %>
    <% end %>

    <%# Tells the server whether to bother sending a login code at all. The
        code is only redeemable in the browser that requested it, so it is
        noise on desktop. Unset means desktop — the safe default, since a
        touch user with JS off still gets a working magic link. %>
    <script>
    (() => {
      const field = document.getElementById("touch-device");
      if (!field || !window.matchMedia) return;

      const isTouch = window.navigator.standalone === true ||
        window.matchMedia("(display-mode: standalone)").matches ||
        window.matchMedia("(pointer: coarse)").matches;

      if (isTouch) field.value = "1";
    })();
    </script>
  <% end %>
</div>
```

- [ ] **Step 4: Render the code form only for touch devices**

In `app/views/sessions/_pending.html.erb`, replace:

```erb
<details id="code-details">
  <summary>Or enter the code instead</summary>
  <%= form_with url: verify_login_code_path, method: :post do |f| %>
    <div class="form-field" style="margin-top:.75rem;">
      <%= f.label :code, "6-digit code from the email" %>
      <%= f.text_field :code, inputmode: "numeric", pattern: "[0-9]*", maxlength: 6, autocomplete: "one-time-code", placeholder: "123456", required: true %>
    </div>
    <%= f.submit "Verify code →", class: "btn btn-primary", style: "width:100%;padding:.75rem;" %>
  <% end %>
</details>
```

with:

```erb
<% if session[:pending_login_touch] %>
  <details id="code-details">
    <summary>Or enter the code instead</summary>
    <%= form_with url: verify_login_code_path, method: :post do |f| %>
      <div class="form-field" style="margin-top:.75rem;">
        <%= f.label :code, "6-digit code from the email" %>
        <%= f.text_field :code, inputmode: "numeric", pattern: "[0-9]*", maxlength: 6, autocomplete: "one-time-code", placeholder: "123456", required: true %>
      </div>
      <%= f.submit "Verify code →", class: "btn btn-primary", style: "width:100%;padding:.75rem;" %>
    <% end %>
  </details>
<% end %>
```

- [ ] **Step 5: Guard the pending script against the now-optional code form**

In the same file, replace:

```erb
  const isStandalone = window.navigator.standalone === true ||
    (window.matchMedia && window.matchMedia("(display-mode: standalone)").matches);
  const message = document.getElementById("pending-message");
  const details  = document.getElementById("code-details");

  if (isStandalone) {
    message.textContent = "Check your email for a 6-digit code and enter it below.";
    details.open = true;
    details.querySelector("summary").style.display = "none";
    return; // no shared storage for a same-browser link click to land in, so polling could never resolve
  }
```

with:

```erb
  const isStandalone = window.navigator.standalone === true ||
    (window.matchMedia && window.matchMedia("(display-mode: standalone)").matches);
  const message = document.getElementById("pending-message");
  const details = document.getElementById("code-details");

  // `details` is absent on desktop, where the server omits the code form
  // entirely. Requiring it here means a standalone app that somehow has no
  // code form still falls through to polling rather than stranding the user
  // on a message about a field that isn't there.
  if (isStandalone && details) {
    message.textContent = "Check your email for a 6-digit code and enter it below.";
    details.open = true;
    details.querySelector("summary").style.display = "none";
    return; // no shared storage for a same-browser link click to land in, so polling could never resolve
  }
```

- [ ] **Step 6: Run the specs to verify they pass**

Run: `bundle exec rspec spec/requests/sessions_spec.rb`
Expected: PASS — all specs in the file.

- [ ] **Step 7: Run the full suite and the linter**

Run: `bundle exec rspec`
Expected: PASS — 0 failures. A broken ERB template would surface here as a 500 in any spec that renders the login page.

Run: `bin/rubocop app/controllers/sessions_controller.rb spec/requests/sessions_spec.rb`
Expected: `no offenses detected`.

- [ ] **Step 8: Manually verify in a browser**

Start the app: `bin/dev`

1. On a **desktop** browser, go to `/login` and submit the form. Confirm the pending page shows "Check your email…" with **no** "Or enter the code instead" section anywhere.
2. Open the email (via `letter_opener`, which opens automatically in development) and confirm it contains the link and **no** "enter this code" line.
3. In a second tab, click the link. Confirm the first tab auto-redirects to the dashboard within ~3-6 seconds.
4. Log out. Using device emulation (Chrome DevTools → toggle device toolbar → any phone preset, which sets `pointer: coarse`), reload `/login` and submit again. Confirm the pending page now **does** show the collapsed "Or enter the code instead" section, and the email **does** contain a 6-digit code.
5. Enter that code and confirm it logs you in.
6. If you can, repeat on the installed iOS PWA and confirm the code field is already open with its summary hidden, and that no polling runs.

Report any deviation before proceeding — do not mark this task done from test-suite output alone, per this app's UI/JS verification requirement.

- [ ] **Step 9: Commit**

```bash
git add app/views/sessions/new.html.erb app/views/sessions/_pending.html.erb spec/requests/sessions_spec.rb
git commit -m "Show the login code form only for touch-device login requests"
```

---

## Self-Review Notes

- **Spec coverage:** "Definition of touch device" → Task 2 Step 3's script (all three clauses). "Signal capture" → Task 2 Step 3. "Decision point" → Task 1 Steps 4-5. "Rendering" → Task 2 Steps 4-5. "Cleanup" → Task 1 Step 6. "Testing" (both new spec pairs plus the required update to the existing code specs) → Task 1 Steps 1-2 and Task 2 Step 1. The spec's "code digest still always generated" decision is honored by never touching `User`, and is restated in Global Constraints. Out-of-scope items are not implemented anywhere.
- **Placeholder scan:** no TBD/TODO; every step has literal code, exact file paths, and runnable commands.
- **Type consistency:** the `touch_device` param name is identical in Task 2's `f.hidden_field :touch_device` and Task 1's `params[:touch_device] == "1"`, and the `"1"` sentinel matches on both sides. `session[:pending_login_touch]` is set in Task 1 Step 5, deleted in Task 1 Step 6, and read in Task 2 Step 4. The `touch-device` element id in Task 2 Step 3's `hidden_field` matches the `getElementById("touch-device")` in the same step's script. `code-details` in Task 2 Step 4 matches `getElementById("code-details")` in Step 5.
