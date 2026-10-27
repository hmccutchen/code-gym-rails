# app/javascript/controllers/review_alternates_controller.js

## What it owns

One reviewed section's "Explain differently" control: the request, the
paragraph it inserts, the cap, and the live region beside it.

## One controller per section replaces the once-guards

The inline script ran once per request and used
`.explain-differently:not([data-alt-wired])` plus an
`@ai_review_script_emitted` flag, because this partial renders once per history
entry and the script would otherwise bind every control again on each render.
A controller instance is created per element, so both guards are gone and
nothing can double-bind.

## The status is set and never cleared

The explanation itself lands outside the live region, so the region is the only
thing that announces anything happened. Clearing it after a success would take
that announcement away from a screen reader that had not yet reached it.

## The explanation is inserted as HTML

The reply carries the explanation as plain text (`alternate`) and as
glossary-wrapped HTML (`alternate_html`), which `glossary_wrap` has already
escaped. The controller inserts the HTML, so its terms work like the rest of
the review's; the layout's glossary controller listens on the page and finds
a term by its class. The plain text is what the server saves, so nothing here
keeps a copy. A reply without a string `alternate_html` can only come from a
server running the earlier code during a deploy; its explanation was already
paid for, so the controller shows the plain `alternate` with `textContent`.
