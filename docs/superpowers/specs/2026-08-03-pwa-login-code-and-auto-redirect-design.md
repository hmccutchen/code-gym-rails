# PWA Login Code + Cross-Tab Auto-Redirect

## Context

Two independent, unrelated login-friction problems, bundled into one PR because both touch `SessionsController` and the login screen.

**Fix 1 — PWA login code.** On iOS, tapping the magic-link email always opens Safari, never the installed home-screen PWA — iOS fully isolates cookie storage between a standalone PWA and Safari, even on the same device and site. A session created by clicking the link in Safari can never be inherited by the PWA. This is a hard platform constraint, not a gap in our implementation.

**Fix 2 — cross-tab auto-redirect.** On desktop/normal browser tabs, clicking the magic link opens a new tab to complete login, leaving the original "check your email" tab stale. Unlike Fix 1, this is purely a missing feature: a normal tab and the tab opened by the link share the same browser storage, so there's no technical reason the original tab can't resolve itself automatically.

Investigation confirmed neither fix has any prior implementation: no `login_code` column exists, no rate-limiting gem is installed, and the "4-day session extension" referenced as a dependency of Fix 1 was never actually built (no `session_store.rb`, no `expire_after` configured anywhere — Rails' default cookie session has no explicit expiration).

## Fix 1: Short login code

### Data model

Migration adds two columns to `users`:

| Column                 | Type    | Purpose                                             |
| ---------------------- | ------- | ---------------------------------------------------- |
| `login_code_digest`    | string  | BCrypt digest of a 6-digit numeric code               |
| `login_code_attempts`  | integer, default 0 | Wrong-guess counter, reset on each new code |

No new expiry column — `login_token_sent_at` becomes the shared expiry clock for both the link and the code. This is deliberate: the spec requires the code to be "a different presentation of the same mechanism, not a separate or weaker one," so both presentations share one expiry and one invalidation path.

### `User` model changes

- `generate_login_token!` is extended to also generate a random 6-digit code, store its BCrypt digest, and reset `login_code_attempts` to 0. It returns both the raw token and the raw code (e.g. as a small struct or two-element return) so `SessionsController#create` can pass both to the mailer.
- `clear_login_token!` is extended to also clear `login_code_digest` and reset `login_code_attempts`. Because both the link path (`verify`) and the code path (below) call this on success, using either invalidates both — satisfying "a stale one can't be replayed after the other was used."
- New `User.authenticate_login_code(email:, code:)`:
  - Looks up the *active* user by email, scoped to `login_token_sent_at > TOKEN_EXPIRY.ago` (same expiry window as the link), mirroring the existing two-step BCrypt lookup pattern in `find_by_login_token`.
  - On a correct code: calls `clear_login_token!` and returns the user.
  - On an incorrect code: increments `login_code_attempts`. If this reaches 5, also calls `clear_login_token!` (both digests cleared, forcing the user to request a fresh link/code). Returns `nil` in both the wrong-guess and lockout cases — the controller can't distinguish "wrong code" from "locked out" from the return value alone, so it re-derives the attempts-remaining message from the user record if needed, or just shows a generic "Incorrect or expired code" message either way (simplest; avoids leaking attempt counts to an attacker).

### Mailer

`UserMailer.magic_link(user, raw_token, raw_code)` — the template gains a line below the existing link: "Or, if you're using the installed app, enter this code: **123456**." No change to the existing link-click flow.

### Login screen / controller flow

- `POST /login` (`SessionsController#create`) is unchanged except it now also gets `raw_code` back from `generate_login_token!` (passed to the mailer). It additionally sets `session[:pending_login_email] = email` before redirecting back to `/login`. This is not sensitive data (it's the email the user just typed), and it's what lets the `/login` GET view know to render the "pending" state across reloads instead of just a one-shot flash.
- `GET /login` (`SessionsController#new`): if `session[:pending_login_email]` is present, render a "pending" partial instead of the plain email/name form. This partial always includes the code-entry field in the DOM; inline JS (see below) decides how prominently to surface it and whether to poll.
- New `POST /login/code` → `SessionsController#verify_code` (added to the controller's existing `skip_before_action :require_login`/`:require_api_key`): reads `code` from the form and `email` from `session[:pending_login_email]` (not from client-supplied hidden input, so it can't be tampered with to target another account). Calls `User.authenticate_login_code`; on success sets `session[:user_id]`, clears `session[:pending_login_email]`, redirects to `root_path`. On failure, re-renders the pending state with an inline error, no redirect.
- Successful `GET /auth/verify` (existing link flow) also clears `session[:pending_login_email]` alongside its existing `clear_login_token!` call — needed because that request may be happening in a *different* tab/browser context than the one holding the pending-state cookie (see Fix 2), but when it is the same context, this keeps state consistent.

### Standalone (PWA) vs. normal-tab UI branching

The pending-state partial's inline script checks `window.navigator.standalone || matchMedia('(display-mode: standalone)').matches` once on load:

- **Standalone (PWA):** show the code field prominently with a short explanation ("Check your email for a 6-digit code and enter it below"). Do not start polling — there is no shared storage for a same-browser link click to ever land in, so polling could never resolve.
- **Normal tab:** show "Check your email — this page will update automatically once you click the link" as the primary message, with the code field present but visually secondary (an expandable "or enter the code instead" affordance). Start polling (Fix 2).

### Session lifetime

Add `config/initializers/session_store.rb`:

```ruby
Rails.application.config.session_store :cookie_store, key: "_code_gym_session", expire_after: 2.days
```

Confirmed via investigation that no such file exists today — this is new, not a restoration of prior behavior. 2 days (not 4, per user direction) — long enough that a PWA login via code stays useful across a normal usage gap, without extending the window an attacker has if a device is lost.

## Fix 2: Cross-tab auto-redirect

### Mechanism

No new correlation token or cross-tab messaging is needed. Rails' cookie session store keeps one encrypted session cookie per browser per origin, shared by every tab. When the tab opened by the magic link completes `GET /auth/verify` and the server sets `session[:user_id]`, the response's `Set-Cookie` updates that shared cookie. The *original* tab's very next request — the poll — automatically carries the updated cookie, because it's the same browser-managed cookie jar. This only works because both tabs are in the same normal-browser storage context, which is exactly the case Fix 2 is scoped to (never the PWA case).

### Status endpoint

New `GET /login/status` → `SessionsController#status` (also skips `require_login`): returns `{ authenticated: current_user.present? }` as JSON. Deliberately minimal — reuses `logged_in?`/`current_user`, already available on every controller.

### Polling script

Added to the pending-state partial, active only in the non-standalone branch. Mirrors the existing pattern in `app/views/dashboard/_generating.html.erb` (fetch + `setTimeout` retry loop, capped attempts, wrapped in an IIFE so re-rendering the partial doesn't redeclare top-level bindings):

- Poll `/login/status` every 3 seconds.
- On `authenticated: true`, `window.location.href = "/"` (equivalent to reload-and-redirect; no need for a full page reload first since the destination is different from the current page).
- Stop after ~10 minutes (200 attempts at 3s) to avoid an abandoned tab polling forever — matches the spec's stated timeout, same order of magnitude as the dashboard's own polling cap philosophy (that one caps at ~2 minutes for a much faster job; this one is intentionally longer since a human has to go read an email).

## Out of scope / explicitly not changed

- No changes to the magic-link `verify` flow's core security properties (BCrypt digest compare, 15-minute expiry, one-time use).
- No rate-limiting gem (e.g. rack-attack) — the per-token attempt counter is sufficient for this specific brute-force surface and keeps the change scoped.
- No changes to `PreviewMail`/`PreviewSeed` — magic-link and code delivery both go through the existing `UserMailer` path unchanged in preview apps.

## Testing plan

Two independent spec groups, no shared setup beyond the existing login-token factory/helpers:

**Fix 1** (`spec/models/user_spec.rb`, `spec/requests/sessions_spec.rb`):
- Code generated alongside token; correct digest verification.
- Wrong code increments `login_code_attempts`; 5th wrong attempt clears both digests (subsequent correct-code and correct-link attempts both fail).
- Using the link first invalidates the code, and vice versa.
- Code expires with the same 15-minute window as the link.
- `POST /login/code` success sets session and redirects to root; failure re-renders with error and does not set session.

**Fix 2** (`spec/requests/sessions_spec.rb`):
- `GET /login/status` returns `authenticated: false` before verification.
- After a separate request in the same spec's session completes `GET /auth/verify`, a subsequent `GET /login/status` in that same test session returns `authenticated: true` — this is the request-spec equivalent of "two tabs, one cookie jar," since RSpec request specs share one cookie-carrying session across calls by default.

## Migration

One migration: `add_login_code_to_users` — adds `login_code_digest:string` and `login_code_attempts:integer, default: 0, null: false` to `users`.
