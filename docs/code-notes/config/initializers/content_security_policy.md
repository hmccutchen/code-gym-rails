# `config/initializers/content_security_policy.rb`

The policy that makes the Stimulus convention enforceable. Before it, "put page
behavior in a controller" was a habit a reviewer had to catch; now an inline
`<script>` is dead code in the browser, and
`spec/conventions/app_views_spec.rb` fails on one before it ever ships.

## `script-src`

Three sources, and each is there for a reason.

`'self'` covers `code_gym_bootstrap.js` and every pinned module, since
Propshaft serves them from this origin.

`https://cdn.jsdelivr.net` covers the two dynamic imports:
`mermaid_controller.js` loads `mermaid@11.17.2` and `parsons_controller.js`
loads `sortablejs@1.15.6`. A dynamic `import()` is checked against the host
allowlist, not against the nonce of the module that issued it, so the origin
has to be named outright.

The nonce covers the three tag kinds `javascript_importmap_tags` emits — the
inline importmap JSON, the `type="module"` entry tag, and every `modulepreload`
link. importmap-rails passes `request&.content_security_policy_nonce` on all
three unprompted, so nothing in the layout had to change.

`'strict-dynamic'` is deliberately absent. It would void the host allowlist,
and the two CDN imports depend on it.

## The nonce generator

Rails' own scaffold suggests `request.session.id.to_s`. That is wrong here: a
signed-out request can have no session id yet, which renders `'nonce-'` — a
value matching nothing, which would block the importmap on the login page. A
fresh `SecureRandom.base64(16)` per request cannot do that.

## `style-src` keeps `'unsafe-inline'`

Thirty-five `style=` attributes across the views, plus `<style>` blocks in ten
of them including the layout. #357 is about scripts; moving every one of those
into a stylesheet is a separate change with its own risk, and a policy that
blocked them would break pages today.

## What it costs the browser specs

Playwright's `wait_for_function` compiles its string predicate with `eval`
inside the page, which this policy refuses. Nine call sites moved to
`wait_for_js_condition`, which polls through `evaluate` instead — that path
goes through CDP and is not subject to `script-src`. Bypassing CSP in the
browser context was the alternative and is worse: the system suite is the only
place that proves mermaid and SortableJS run under the real policy.
