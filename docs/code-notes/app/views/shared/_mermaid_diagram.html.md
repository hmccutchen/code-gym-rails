# app/views/shared/_mermaid_diagram.html.erb

## Locals

`source` is the Mermaid text. A blank source, or one `MermaidSource` refuses,
renders nothing at all, so call sites stay a single unconditional line and a
row from before diagrams existed looks the same as a section that chose not
to have one.

`collapsible` (default true) wraps the container in its own closed
`<details>`, matching the dropdown in `shared/_concept_reference.html.erb`.
Architecture's diagram passes `collapsible: false` because it already renders
inside its own `<details class="ref">` (the "Reference — tradeoffs" box), and
a second nested disclosure there would turn a one-click reveal into two.

## Emitting the script once

The partial renders up to three times per exercise and once per history
entry, so the module script goes into the layout's shared `:page_scripts`
region only on the first call that has a diagram. Otherwise every container
would ship its own identical copy. The script loops over every
`.mermaid-diagram` on the page, so one copy renders them all.

## Module script

The script loads only on pages that have a diagram. Visibility is the
disclosure's job, not the script's.

A failed parse or render removes the whole `<details>` ancestor, not only the
diagram div. A CDN or module load failure does the same for every diagram
still pending, since several can be pending at once. That way a bad diagram
never leaves an empty, clickable disclosure behind, as long as the script
itself runs.

If the module never executes at all (a CSP blocking `type="module"`, or
something intercepting the script tag before it parses, which is narrower
than the CDN import rejecting), the disclosure stays visible with nothing
behind it once opened. The app already requires JavaScript for rating,
autosave and submit, so this is an accepted, narrow residual risk the script
cannot guard against. Nothing else on the page depends on it running.

## Mermaid import

The version is pinned exactly, not `@11`, so a Mermaid release cannot change
behavior without a deliberate bump. SRI and CSP hardening for this CDN import
is a known gap, deferred to its own PR, because enabling a CSP interacts with
every inline script in the app.

## removeFailed

The function walks up to the enclosing `<details>` only when this partial
created it, which `data-owns-details` marks on the collapsible branch.
Architecture's div sits inside its own "Reference — tradeoffs" `<details>`,
which this partial does not own and must never remove; a failed diagram there
takes out only the div. When the flag is set, an ancestor is always found,
because that div is a direct child of the `<details>` rendered right above it.
