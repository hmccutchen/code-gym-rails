# Gating the Login Code on Touch Devices — Design

**Status:** approved, pending implementation
**Builds on:** `2026-08-03-pwa-login-code-and-auto-redirect-design.md`

## Problem

The login code shipped as an unconditional escape hatch: every login page offers
an "Or enter the code instead" section, and every magic-link email carries the
line "Or, if you're using the installed app, enter this code: 123456". Desktop
users see both, even though the code exists solely so an installed iOS PWA can
log in without bouncing through Safari.

Worse, the code is useless to them. `SessionsController#verify_code` resolves the
account from `session[:pending_login_email]`, so a code is only redeemable in the
same browser that requested it. A desktop requester can never do anything with
theirs — it is pure noise in the email and pure clutter on the page.

## Goal

Offer the code — on the page and in the email — only when the login was requested
from a touch device. Desktop users should never learn the mechanism exists.

## Definition of "touch device"

Any of:

- `window.navigator.standalone === true` (installed iOS PWA)
- `matchMedia("(display-mode: standalone)").matches` (installed PWA, standards path)
- `matchMedia("(pointer: coarse)").matches` (any phone/tablet browser)

The third clause is what extends the feature past the installed PWA to mobile
Safari and Chrome, which is deliberate: someone reading the email in their phone's
mail app and returning to the browser benefits from the code even when they
haven't installed the app.

Rejected: viewport-width detection via the app's existing `600px` breakpoint,
which would misfire on a narrowed desktop window; and server-side User-Agent
sniffing, which is brittle (iPadOS reports as desktop) and makes the login page's
response vary by UA.

## Approach: decide once, on the server

The signal is captured on the client but resolved on the server, so a single
value drives both the email and the page. This makes email/UI consistency
structural — there is no second copy of the detection logic to drift.

### 1. Signal capture — `app/views/sessions/new.html.erb`

The email form gains a hidden field:

```erb
<%= f.hidden_field :touch_device, value: "", id: "touch-device" %>
```

plus a small inline script that sets its value to `"1"` when the definition above
holds. Inline `<script>` is this app's established convention; it loads no JS
framework.

Absent or unset means desktop. That default is deliberately the safe one: a
mobile user with JavaScript disabled gets no code, but still gets a fully working
magic link.

### 2. Decision point — `SessionsController#create`

```ruby
touch_device = params[:touch_device] == "1"

UserMailer.magic_link(user, raw_token, touch_device ? user.raw_login_code : nil).deliver_later

session[:pending_login_email] = email
session[:pending_login_touch] = touch_device
```

`UserMailer#magic_link` already takes `raw_code` as an optional third argument and
`magic_link.text.erb` already guards on `@raw_code.present?`, so passing `nil`
omits the line with no mailer change.

The code digest is still generated and stored on every request. An un-emailed
code is inert — nobody ever sees it, and `verify_code` is bound to the requesting
browser's own session — so leaving `generate_login_token!` unconditional avoids
threading a presentation concern down into the model.

A forged `touch_device=1` from a desktop client merely mails that person their own
code, which is no weaker than the link already in the same email. It is not a
security boundary and is not treated as one.

### 3. Rendering — `app/views/sessions/_pending.html.erb`

The `<details>` block renders only when `session[:pending_login_touch]` is true.
Because the server omits it entirely on desktop, there is no flash of a visible
code field before JavaScript could hide it.

The inline script's responsibilities shrink to what only the client can know:

- **Standalone:** open the `<details>`, hide its `<summary>`, swap the message to
  "Check your email for a 6-digit code and enter it below", and do not poll —
  a link click in the mail app can't land in the PWA's session.
- **Otherwise:** poll `GET /login/status` and redirect on success, unchanged.

The script must guard on the `<details>` element existing, since desktop no
longer renders it.

### 4. Cleanup

`session[:pending_login_touch]` is deleted alongside `session[:pending_login_email]`
in both `verify` and `verify_code`, so a completed login leaves no stale state.

## Testing

New request specs in `spec/requests/sessions_spec.rb`:

- `POST /login` with `touch_device: "1"` → the delivered email contains a 6-digit
  code, and the pending page renders a form posting to `/login/code`.
- `POST /login` without it → the email contains no "enter this code" line, and the
  pending page renders no `/login/code` form.

The existing `POST /login/code` specs scrape the code out of the delivered email,
so they must be updated to pass `touch_device: "1"`. This is a required change to
keep them meaningful, not a weakening of an assertion — they continue to assert
the same login, lockout, and invalidation behavior.

Unchanged and still not covered by specs: the detection script itself and the
standalone branch, which need a real browser. Same limitation as the existing
polling script.

## Out of scope

- Any change to the code's expiry, lockout, or invalidation rules.
- Any change to the magic-link flow's security properties.
- Rate limiting beyond the existing per-token attempt counter.
