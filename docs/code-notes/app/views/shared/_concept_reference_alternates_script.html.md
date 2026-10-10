# app/views/shared/_concept_reference_alternates_script.html.erb

## Emit-once guard

This script wires every "try a different explanation" control on the page.
Its partial renders once per section that has a cached reference, and
/history renders every entry's sections, so the script is emitted into the
layout's shared `:page_scripts` region only on the first call anywhere on the
page. This is the same guard and reasoning as `shared/_mermaid_diagram`. The
single copy still reaches every control because the script scans the whole
document, not just the caller's own markup.

## `framings`

The map is keyed by reference id rather than by container, because one
reference can render several times on a page: two sections of a day can carry
the same concept, and /history renders many days. Per-container state would
let the same person spend `MAX` paid calls in each copy of the same reference.

## Reading the reply

A session that expired while the page sat open redirects to the HTML login
form, and fetch follows that redirect transparently: the status is 200 and
`res.ok` is true, but the body is a page. Parsing therefore has to fail
closed. An earlier version fell back to `{}`, which passed the `res.ok` check,
then appended an undefined framing and removed the control. A proxy error or
an unhandled 500 lands in the same branch.

## `p.tabIndex = -1`

Each inserted framing is focusable but out of the tab order. The only thing
that focuses it is the cap branch, where the button holding focus is about to
be removed.

## Status text

The status is set and never cleared. The framing is inserted outside this
live region, so clearing the status left a screen reader with silence on
success. The wording at the cap also has to say the control is going away,
since its removal is otherwise unannounced.

## Focus before removal

Focus moves to the new framing before the buttons are removed. Removing the
focused button drops focus to the body and loses the keyboard user's place.

## Re-enabling after a failure

Only re-enable what the cap still allows. A failure spends nothing
server-side, but a retry after the cap was reached in another copy of this
reference would just return 422.
