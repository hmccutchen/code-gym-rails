# Secret-Gated Test Login — Design

**Date:** 2026-07-09
**Status:** Approved by Hassan (interim feature, removed when a sending domain is purchased)

## Problem

Magic-link login works end-to-end, but production email delivery uses Resend's
`onboarding@resend.dev` test sender, which only delivers to the Resend account
owner's inbox and is spam-prone. Until a sending domain is bought and verified,
the owner needs a way to log into production without the email round-trip.
Approaches involving a shared mail viewer (`letter_opener_web`) or on-screen
links were rejected: login links must remain private per user, and free email
providers with single-sender verification (Brevo) were deferred. SendGrid was
ruled out (free tier retired May 2025; 60-day trial only).

## Decision

Keep the existing magic-link + Resend implementation untouched. Add one
interim, secret-gated login route.

## Behavior

- **Route:** `GET /test_login?secret=<value>&email=<address>` — GET so the
  owner can bookmark it for one-click login.
- **Gate:** active only when the `TEST_LOGIN_SECRET` env var is present on the
  web service. The `secret` param is compared with
  `ActiveSupport::SecurityUtils.secure_compare(params[:secret].to_s, ENV[...])`
  — `.to_s` so a missing param can't raise `NoMethodError` before the compare
  runs (`secure_compare` itself digests inputs, so unequal lengths are safe;
  it's `fixed_length_secure_compare` that raises).
- **All failure modes return 404** (env var unset, wrong/missing secret,
  unknown email) so the route is invisible when disabled and reveals nothing
  when probed.
- **On success:** find the existing user by email — the param is stripped and
  downcased first, matching how `SessionsController#create` normalizes emails
  (no user creation) — set
  `session[:user_id]` exactly as `SessionsController#verify` does, redirect to
  root with a notice.
- **Controller placement:** a new action on `SessionsController` (it already
  skips `require_login` / `require_api_key` and owns session establishment).

## Security posture (accepted trade-offs)

- Equivalent to a single shared password known only to the owner; 404-cloaked.
- The secret appears in URL query strings and therefore in Railway request
  logs. Accepted for an owner-only interim tool in exchange for
  bookmarkability.
- Disabling requires no deploy: unset `TEST_LOGIN_SECRET` on Railway.

## Lifecycle / removal

- CLAUDE.md "What Still Needs Work" gains an item: after buying/verifying a
  domain, unset `TEST_LOGIN_SECRET` and delete the route, action, and specs.
- Secret generated with `openssl rand -hex 24`; set on the Railway **web**
  service only (the worker never handles logins).

## Testing

Request specs:
1. Correct secret + known email → logs in (session set), redirects to root.
2. Wrong secret → 404, no session.
3. `TEST_LOGIN_SECRET` unset → 404 even with a "correct-looking" secret.
4. Correct secret + unknown email → 404, no user created.

## Out of scope

- Any change to magic-link flow, Resend delivery, or session duration.
- Teammate self-serve login (revisit when the domain is purchased, per the
  brainstorm: Brevo remains the fallback if the domain is further off than
  expected).
