# app/models/bug_hunt_gotchas.rb

The closed list of language traps a `bug_hunt` day plants, one list per
language. The reasoning and the owner's review of each entry are in
`docs/decisions/bug-hunt.md`.

## Entries

Each entry's `rule` is one line telling the generator which trap to plant.
It reaches only the generation and retry prompts, never the page, the judge
or the duck, because it names the answer.

Every trap is in core Ruby or core JavaScript, and none depends on line
breaks, semicolons or operator precedence, which the formatters rewrite.
JavaScript snippets are ES modules, so no rule mentions `require` or
`module.exports`, and `js_arrow_method` asks for `export` so the module
mode is visible on the page.

`js_foreach_async`'s rule makes the function return a copy of what was
saved. A live array would fill in once the pending saves settle, and the
bug would look fixed by the time a witness compared it.

## `.pick`

Never-seen entries first, in list order, then the one seen longest ago,
with ties in list order: the same shape as `RealSource.pick`. That bounds
the longest wait before an entry comes round again by the size of the
list, which is why entries are appended, never inserted.

## `.last_seen_for`

Reads the picked id from `plan_notes["bug_hunt"]`, never from the section,
so the id stays off everything the page, the judge and the duck read. A cut
entry's id stays in old rows; `.pick` never asks about it.
