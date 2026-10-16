# Folding a section

on the answer form each section is its own open
`<details>`, the disclosure the reference, hint and history already use,
so a section can be folded away by hand. Nothing folds on its own, and
folding is available whatever the section's state. The summary carries
the label, as an `<h2>` so VoiceOver's heading rotor reaches each section
(never give the summary `role="button"`, which would erase it), and a
status line (`SectionStatusHelper#section_status`, the only statement of
it: each save reply carries its text as `section_statuses`, which the
dashboard shows as is): a check and the self-rating
once answered and rated, "in progress" once answered, blank otherwise. One
automatic reopen: editing the answer of a folded, rated section opens it,
since a fold claims the section is settled and a stale rating must never
sit beside changed text. Native `<details>` hides without unmounting, and
nothing inside a section needs to be visible to work — the diagram
renders to an SVG string once at load, the duck and pseudocode controls
fetch on click, and every autosave listener is on `input` — so the fold
is purely visual and the submit gate, rating and autosave are untouched.
Fold state is not persisted: a reload opens every section, which costs one
tap per section and avoids keying browser storage to a response that
regenerate and start-over would have to invalidate. The read-only render
folds the same way, open by default with the label in the summary and no
status line, so on the submitted dashboard a reader can fold the answered
problems away and reach the review below them without scrolling past
every section. Each section inside a History entry folds too.
