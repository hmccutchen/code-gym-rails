---
paths:
  - "app/prompts/learner_items_prompt.rb"
  - "app/models/{learner_note,learner_item,learner_items_reply,note_question,explain_question}.rb"
  - "app/models/learner_item/merge.rb"
  - "app/clients/learner_notes.rb"
  - "app/controllers/{learner_notes,learner_explanations}_controller.rb"
  - "app/controllers/concerns/{learner_notes_gate,learner_note_questions}.rb"
  - "app/views/shared/{_learner_note,_learner_explanation}.html.erb"
  - "app/javascript/controllers/{learner_note,learner_explanation}_controller.js"
  - "spec/**/*learner*"
---

# Learner notes

Each entry states what a change must not break.

- **Off by default.** Nothing here runs unless `LearnerNotes.enabled?`
  (`LEARNER_NOTES` exactly `"1"`) and the account's
  `learner_notes_enabled` setting are both on, and the setting needs the
  account's own key. With either off, every page and prompt is unchanged.
- **What may read notes and items.** `learner_notes_isolation_spec` names
  the files that may name `LearnerNote` or `LearnerItem`. The prompt class
  and the reply boundary read only `LearnerItem`'s limits, never a row.
  Generation, review, the judges, mastery and planning read neither table.
- **The extraction prompt is pure.** `LearnerItemsPrompt` takes values the
  job built: each active section through `SectionContext.render` (no answer
  key), the answer cut to 2,000 characters, the duck turns cut to 1,000 each,
  the day's note and explanation, open items without ids and earlier labels.
  It is never sent a review, a rating, `ConceptMastery`, a server stamp or
  another day's text. Every label reaches it as data through
  `UserText.labelled`, and the worst case, every label at its limit, stays
  within `LearnerItemsPrompt::MAX_ITEMS_BLOCK_CHARS`. Its kind triggers,
  reading rules, report-a-repeat and refine-only-when-new lines are each
  pinned by a snapshot.
- **The reply is checked at the boundary.** `LearnerItemsReply.parse` is
  pure: it drops an item of an unknown kind (a strength included), a concept
  outside the owner's buckets, a label over `LearnerItem::MAX_LABEL_LENGTH`
  or on two lines (never cut), a bad term, and an item with no valid
  evidence. The server stamps each reference with the set's date and ignores
  any id or date in the reply. The reply is parsed with `log_raw: false`.
- **One writer of items.** `LearnerItem.merge!` takes the user row lock,
  expires overdue open rows, then applies the five merge rules in order:
  collapse matching items inside the reply; let an open item with the same
  key absorb its repeat (evidence newest 5, the day in `came_up_on`, a moved
  expiry, its own label kept); count repeats apart from new items and drop
  new items past `LearnerItem::MAX_NEW_PER_DAY` as `over_limit`; hold back a
  match for an item used in the last 30 days (a term outright, another kind
  keeps only evidence from the shaped set onward) as `recently_used`; insert
  with `returned_after` when the key was dismissed and is still kept; then
  displace past `LearnerItem::MAX_OPEN`. A unique violation merges into the
  existing open row. The matching key is `LearnerItem.matching_key` alone.
  Deleting a row keeps no record, so a deleted item holds nothing back.
