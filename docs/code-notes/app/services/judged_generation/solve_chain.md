# app/services/judged_generation/solve_chain.rb

One kind's solves for one generation, in the order the judge made them. A
kind without `judge_solve_options` records nothing, so `JudgedGeneration`
calls the chain the same way for every kind.

## `#record` and `#record_edit_check`

Each entry is a solve plus whether it is its attempt's candidate to ship. A
judged draft or retry starts as the candidate. `#record_edit_check` is told
the edit's outcome by `#confirmed_edit`:

- **Kept:** the edit check becomes the candidate and the pre-edit solve stops
  being one. The pre-edit solve gets no `never_shown_reason`, because an
  edit touches only prose and its pieces and key shipped.
- **Reverted:** the pre-edit solve stays the candidate, and the edit check is
  recorded with `edit_reverted` and its `revert_reason`. It gets no
  `never_shown_reason` either, for the same reason.

## `#settle` and `#solves`

`JudgedGeneration` calls `#settle` with the attempt that shipped, at the
point its control flow keeps a version. `#solves` then reads:

- no settled attempt: the section was dropped, so every solve is
  `shipped: false, never_shown_reason: "section_dropped"`
- an attempt before the settled one: rejected and replaced with freshly
  generated pieces, so `replaced_by_retry`
- the settled attempt: `shipped` is the candidate flag, with no reason

`replaced_by_retry` is safe because a retry never sees the rejected section:
`judged_generation_spec` pins that the retry callable gets only the draft,
kind and concept, and `exercise_draft_spec` that the rendered retry prompt
holds none of the rejected section's text.
