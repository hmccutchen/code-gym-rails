# Diagram loop-repetition instruction + collapsible diagrams

## Why

A real production example exposed two separate gaps in the structure-diagrams
feature (`docs/superpowers/specs/2026-08-10-structure-diagrams-and-duck-explain-design.md`):

1. A `code_review` diagram for an N+1 bug (a method querying `orders`, called
   inside `customers.each`) rendered as a flat, one-time call chain: job →
   method → orders. That's technically accurate but diagnostically empty —
   it's indistinguishable from what a correct, non-buggy version of the same
   code would produce, because it omits the one structural fact that actually
   makes this a bug: the call happens once *per customer*, not once total.
2. Separately, diagrams currently auto-reveal (CSS-hidden, then JS sets
   `display: block` on successful render) rather than being an explicit,
   user-controlled disclosure like the rest of this app's collapsible
   sections (the concept-reference dropdown, the teaching hint, history's
   answers/review sections).

Both are small, targeted fixes bundled into one spec because they touch the
same rendering surface (`shared/_mermaid_diagram.html.erb`) and were raised
in the same conversation — not because they're conceptually one change.

## Part 1: loop-repetition instruction

**Where:** One new bullet in the shared diagram-generation guidance inside
`AiService#build_exercise_prompt` (`app/services/ai_service.rb`), between the
existing "depicts only the structure... never the fix" bullet and the "empty
string when not useful" bullet. This is the only place diagram-generation
prose exists in the codebase — the JSON schema's `"diagram"` field
descriptions elsewhere are one-line type hints, not instructions, and
`build_concept_reference_prompt` has no diagram guidance to touch.

**The new instruction:**

> When the snippet or scenario contains a loop, iteration, or repeated
> invocation that wraps the flow being diagrammed (e.g. a method called
> inside `each`/`for`/`while`), the diagram must make that repetition
> visible — either an explicit loop/iteration node in the call's path, or a
> labeled edge stating the per-item cardinality (e.g. "once per customer",
> "for each order"). A flat one-time call chain is not accurate for code
> that actually repeats. Do not manufacture a loop or cardinality label when
> the snippet has none.

This targets the confirmed failure directly, offers two acceptable
representations rather than mandating one specific Mermaid shape, and the
final sentence is the explicit anti-over-application guard — a snippet with
no loop must not grow one.

**Why this stays within the existing safety boundary:** it sits immediately
after the existing "never diagram the fix... never annotate a node as the
problem" bullet, and asks only for a fact already true of the code as
written (it repeats) — never a hint toward the fix (e.g. "cache this outside
the loop", "batch these queries").

**Constraints (unchanged from the original structure-diagrams spec):** no
change to which section kinds get diagrams, the node-count/syntax
constraints (`flowchart TD`/`graph LR` only, max 8 nodes, no styling
directives), or anything else — this is one additional instruction, not a
redesign.

**Testing:** two new specs in `spec/services/ai_service_spec.rb`, alongside
the existing `"forbids diagramming the fix..."` example, following that
file's established pattern of asserting on the built prompt string directly
(no live provider calls):

1. `"instructs the diagram to show repetition when a loop wraps the flow"` —
   asserts the prompt names the `each`/`for`/`while` trigger and the
   cardinality-labeling / explicit-node options.
2. `"does not force a loop cue on snippets without one"` — asserts the guard
   sentence ("Do not manufacture a loop... when the snippet has none") is
   present, so the anti-over-application clause ships alongside the trigger
   clause, not instead of it.

## Part 2: collapsible diagrams

**Where:** `app/views/shared/_mermaid_diagram.html.erb`, plus one call site.
Six of the seven render sites (`dashboard/_exercise.html.erb` ×3,
`responses/_answered_sections.html.erb` ×3) render the shared partial at the
top level and need no call-site change. The seventh,
`responses/_architecture_section.html.erb:24`, already renders the diagram
*nested inside its own* `<details class="ref">` (the "Reference — tradeoffs"
box, alongside tagline/tradeoffs/senior_lens) — wrapping the shared partial
unconditionally would nest a `<details>` inside a `<details>`, turning a
one-click reveal (open tradeoffs, diagram is right there) into two clicks
(open tradeoffs, then open the diagram). The partial takes a new
`collapsible` local, defaulting to `true`; the architecture call site alone
passes `collapsible: false`, since it's already inside a collapsed box and
doesn't need a second one.

**Markup:** wrap the existing `<div class="mermaid-diagram">` in a
`<details>` only when `collapsible` is true:

```erb
<details class="ref">
  <summary>🗺️ Structure diagram</summary>
  <div class="mermaid-diagram" data-diagram="...">...</div>
</details>
```

reusing the `.ref`/`summary` triangle-and-accent-color CSS that already
styles the concept-reference dropdown
(`details.ref summary::before { content: "▶ "/"▼ " }`, etc. — defined once
in the layout's `<style>` block). This does **not** reuse `.ref-body`: that
class styles the concept reference's plain-text box (dark background,
padding, line-height for prose), and the diagram already has its own boxed
appearance (`.mermaid-diagram`'s border/background/padding) — nesting one
inside the other would double-box it.

**Default state:** closed, matching `shared/_concept_reference.html.erb`'s
baseline (`open` only on a caller-specified exception, which no diagram call
site uses).

**A required behavior change, not just cosmetic:** today `.mermaid-diagram`
is CSS-hidden by default (`display: none`) and the inline Mermaid module
script (also in this partial) reveals it (`style.display = "block"`) only
after a successful parse and render — the stated reason, in the script's own
comment, is that a bad diagram, a blocked CDN, or an offline user should all
silently produce "no diagram," never a broken box. Once the container lives
inside a `<details>`, that CSS/JS toggle becomes redundant: a closed
`<details>` already hides its descendants regardless of their own `display`
value. Both are removed as part of this change — the `display: none` default
in the layout's `.mermaid-diagram` CSS rule, and the
`el.style.display = "block"` line in the success path.

Removing the toggle exposes a real gap that must be fixed, not left as a
side effect: on a **failed** render, the script currently does `el.remove()`
on just the inner `.mermaid-diagram` div. Once that div is nested inside a
`<details>`, removing only the div would leave behind an empty, clickable
`<details><summary>🗺️ Structure diagram</summary></details>` — an
expandable box with nothing inside once opened. The script's failure path
changes to remove the whole `<details>` ancestor instead
(`el.closest("details")?.remove()`, falling back to `el.remove()` if for
any reason no ancestor `<details>` is found), preserving the original "no
diagram" guarantee rather than trading it for "an empty disclosure
triangle."

**Not changing:** the Mermaid module script's loading, parsing, and
rendering logic itself (CDN import, `mermaid.initialize`, `mermaid.parse`/
`mermaid.render`, the dedup-across-multiple-diagrams guard via
`data-mermaid-done`) — only the visibility mechanism and the failure
cleanup target change.

**Testing:** extend the existing request specs — `spec/requests/dashboard_spec.rb`'s
`"structure diagrams"` describe block and `spec/requests/history_spec.rb`'s
diagram examples — to assert the `<details class="ref">`/`<summary>🗺️
Structure diagram</summary>` markup wraps the diagram container, in addition
to their existing assertions on the container/script itself. This matches
this codebase's existing test depth for this feature: request-spec HTML/text
assertions only. No system spec currently exercises live Mermaid parsing or
rendering in a real browser, and this change doesn't add one — doing so
would be new coverage depth beyond what this subsystem has ever had, not a
requirement of this specific change.

## Not building

- No change to which section kinds get diagrams, node-count/syntax
  constraints, or any other part of the original structure-diagrams spec.
- No migration, no schema change — Part 1 is prompt-instruction only; Part 2
  is view/CSS/JS only.
- No system-spec coverage added for live Mermaid rendering (see Testing
  above) — out of scope for this change.
- No live provider regeneration to verify Part 1 — prompt-text assertions
  only, per the explicit choice made during design.
