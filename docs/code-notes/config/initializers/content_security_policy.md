# `config/initializers/content_security_policy.rb`

The policy that makes the Stimulus convention enforceable. Before it, "put page
behavior in a controller" was a habit a reviewer had to catch; now an inline
`<script>`, `on*` handler or `javascript:` URL is dead code in the browser,
and `spec/conventions/app_views_spec.rb` fails on one before it ever ships.
The handler check matches any `on…` attribute or helper key, since the policy
refuses every inline handler whatever its event, and it skips the few Ruby
option words that start the same way (`only:`, `once:`, `one:`, `online`,
`onboarding`) so a helper option is not mistaken for one. It matches at the
assignment, whatever the value looks like, so `onclick: handler` and an
unquoted `onclick=go()` or a string key like `"onclick" =>` fail as surely as
a quoted one, and a `javascript:` URL fails quoted or not. The script check
covers the helpers that write a `<script>` tag (`javascript_tag`,
`tag.script`, and `content_tag` or `tag` given `:script` or `"script"`) as
well as a literal one.

## `script-src`

Three sources, and each is there for a reason.

`'self'` covers `code_gym_bootstrap.js` and every pinned module, since
Propshaft serves them from this origin.

Two package directories on `cdn.jsdelivr.net` cover the two dynamic imports:
`mermaid_controller.js` imports the `mermaid` pin and `parsons_controller.js`
the `sortablejs` pin. A dynamic `import()` is checked against the source
list, not against the nonce of the module that issued it, so the source has to
be named outright.

The versions are written once, in those pins in `config/importmap.rb`. The
initializer builds each directory from a pin's URL, cut after its
`npm/<package>@<version>/` segment. It draws its own `Importmap::Map` from that
file, because `Rails.application.importmap` is still `nil` when
`config/initializers` load: importmap-rails sets it in its engine's
initializer, which runs after the application's. A pin to any other host adds
no source, so it would be blocked until the initializer learns that host.

They are directories, not the bare host. jsdelivr serves any npm package and
any public GitHub repository (`/gh/<user>/<repo>/`), so allowing the whole
host would let injected markup load a script anyone can publish, which is the
attack the policy is there to stop. A source ending in `/` matches every path
under it, which covers mermaid's own chunk imports from `dist/chunks/`.
Bumping either version means changing its pin, and the directory follows.
`spec/requests/content_security_policy_spec.rb` reads every remote URL in
`config/importmap.rb` and the page scripts and fails when one falls outside
the policy's sources. It also fails when a page script names a remote URL
itself, since `bin/importmap audit` reads only `pin` lines and would never
check that package.

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
