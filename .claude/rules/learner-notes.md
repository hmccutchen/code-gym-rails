---
paths:
  - "app/prompts/{learner_items_prompt,explanation_reply_prompt}.rb"
  - "app/models/{learner_note,learner_item,learner_items_reply,explanation_reply,note_question,explain_question,learner_extraction,learner_day}.rb"
  - "app/models/learner_item/merge.rb"
  - "app/clients/learner_notes.rb"
  - "app/jobs/{extract_learner_items,sweep_learner_notes}_job.rb"
  - "app/controllers/{learner_notes,learner_explanations,account_learner_items,account_learner_notes}_controller.rb"
  - "app/views/accounts/_learner_notes.html.erb"
  - "app/helpers/learner_notes_helper.rb"
  - "app/controllers/concerns/{learner_notes_gate,learner_note_questions}.rb"
  - "app/views/shared/{_learner_note,_learner_explanation,_learner_explanation_reply}.html.erb"
  - "app/javascript/controllers/{learner_note,learner_explanation}_controller.js"
  - "spec/**/*learner*"
---

# Learner notes

Each entry states what a change must not break. The full decision, with its
reasoning, is `docs/decisions/learner-notes.md`; read it before changing
this area.

- **Off by default.** Nothing here runs unless `LearnerNotes.on_for?(user)`:
  `LEARNER_NOTES` exactly `"1"`, the account's `learner_notes_enabled`
  setting on, and the account's own key. It is the one statement of that
  rule; the gate, the job and its queueing read it, and a view reads the
  gate's helpers. With any of them off, every page and prompt is unchanged,
  except that an account whose setting is on without its own key keeps the
  Account page's turn-off control.
- **What may read notes and items.** `learner_notes_isolation_spec` names
  the files that may name `LearnerNote` or `LearnerItem`, or a
  `learner_note`/`learner_item` name inside a longer one.
  `PracticeGeneration` may call `forget_learner_note!` and nothing else of
  either, since it deletes a replaced set's note and reads nothing. The prompt class
  and the reply boundary read only `LearnerItem`'s limits, never a row.
  Generation, review, the judges, mastery and planning read neither table.
- **The boxes are decided from values.** `LearnerDay` (pure, like
  `NoteQuestion` and `ExplainQuestion`) derives the sections passed over,
  the note question, the explain default and the explain box from values
  `LearnerNoteQuestions` reads once a request; a controller only picks a
  status and a partial.
- **The extraction prompt is pure.** `LearnerItemsPrompt` takes values the
  job built: each active section through `SectionContext.render` (no answer
  key), the answer cut to 2,000 characters, the duck turns cut to 1,000 each,
  the day's note and explanation, open items without ids (only those still
  open on the owner's local date, `LearnerItem.still_open`, the rule the
  Account page lists by) and earlier labels.
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
  `LearnerItemsReply::MAX_REPLY_CHARS` (a repeat of every open item plus a
  day's new items, every field at its limit) sets the call's token cap in
  `CallProfiles`, so raising a limit raises the cap.
- **One writer of items.** `LearnerItem.merge!` takes the user row lock,
  expires overdue open rows, then applies the five merge rules in order:
  collapse matching items inside the reply; let an open item with the same
  key absorb its repeat (evidence capped at 5, note and explanation
  references kept first and the rest newest first, the day in `came_up_on`, a moved
  expiry, its own label kept); count repeats apart from new items and drop
  new items past `LearnerItem::MAX_NEW_PER_DAY` as `over_limit`; hold back a
  match for an item used in the last 30 days (a term outright, another kind
  keeps only evidence from the shaped set onward) as `recently_used`; insert
  with `returned_after` when the key was dismissed and is still kept; then
  displace past `LearnerItem::MAX_OPEN`. A unique violation merges into the
  existing open row. The matching key is `LearnerItem.matching_key` alone.
  Deleting a row keeps no record, so a deleted item holds nothing back.
- **The call after submission.** `ExtractLearnerItemsJob` runs on
  `provider_calls` at `JobPriority::BACKGROUND`, with `user_id:` in its
  arguments so account deletion finds a waiting fallback. A set has two
  triggers: the fallback, scheduled at submit for the later of local
  midnight and an hour after, and one early run, after the explanation's
  save or at submit on a day with no explain question. Each run takes an
  `AdvisoryLock` claim on the set and re-reads the set's ledger and the note
  row inside `uncached`; a fallback that finds the claim held queues itself
  again. The ledger is `LearnerExtraction`: text-free counts in
  `plan_notes["learner_extraction"]` on the `DailyExercise`, written under
  the user share lock and the exercise row lock, merging only that key. The
  job never creates a note row. The no-call checks run in order (learner
  notes off for the account, `KeyHold.holds?`, nothing to read) and each
  closes the set with no attempt counted. The attempt is saved before the
  call leaves, so a worker that dies mid-call has spent it. An early run
  calls only at zero attempts and closes the set only on success; the
  fallback calls below two and closes the set before its call leaves. The
  merge takes a `still_there:` check from the job, called under the user row
  lock, and writes no item citing a note or explanation deleted during the
  call, and nothing once the set was replaced. A set or account deleted
  mid-call is logged, never raised. An extraction failure never touches
  `generation_account_failures`. Its log line carries counts only.
- **The reply to an explanation.** `ExplanationReplyPrompt` takes only the
  concept's name, the question's phrasing and the explanation: no review
  text, answer key, answer, duck turn, note, item, other day or
  `ConceptMastery`. Its system prompt carries the five reply rules, and a
  correct explanation gets a null `correction`. `ExplanationReply.parse`
  accepts one `sound` line and a `correction` line or null, each at most
  `ExplanationReply::MAX_LENGTH` characters; anything else is a failed call.
  The purpose is `explanation_reply` (250-token cap, the default read
  timeout, no caching, each provider's default route). The reply is the
  provider's words, so extraction and generation never read it.
  `POST /learner_explanation/reply` sits behind `ProviderCallLimits`, like
  the duck, and makes no call with the switch or setting off or without the
  account's own key; the key hold does not stop it, and a failure never
  counts toward the hold. Under the exercise and note row locks it takes the
  `reply_requested_at` claim and counts the attempt on the set's ledger,
  calls outside the locks, and stores the parsed reply only while its claim
  holds. Two attempts at most per set, kept even when the explanation is
  deleted: the page shows Try again once, and a third request is refused. A
  note deleted during the call gets the no-explanation refusal as JSON,
  never a 404 page. The box asks for the reply when a saved box that has not
  asked yet connects.
- **A replaced set starts with no note.** Regenerating a set
  (`PracticeGeneration#commit_replacement`) and Start over
  (`DailyExercise#start_over!`) delete the day's note row in the same
  transaction as their own change, through `LearnerNote.forget_set!`, which
  deletes every item citing that date's `note` or `explanation`, even one
  with other evidence; regeneration replaces `plan_notes` and Start over
  drops the ledger's key, so the set's counts start fresh. The note and explanation saves post the page's draft scope
  and a replaced set refuses them with the refresh text. An extraction run
  carries the response it was queued for and stops when that response was
  replaced.
- **The Account section.** Shown while the setting is offered or the account
  has rows. Delete all shows whenever the account has any learner row,
  including rows the lists leave out (expired, used, or dismissed more than
  30 days ago), and the privacy page says what is listed. Every action takes the user row lock (`LearnerItem.under_owner_lock`).
  "I've got this" (`LearnerItem.dismiss!`) closes an open item as `dismissed`
  with the owner's local date and refuses a closed one. Deleting a note or an
  explanation deletes every item that cited it, even one with other
  evidence, and deletes the row once neither is left; Delete all deletes
  every row and item. No empty marker stays: the set's ledger says it was
  read, and the action discards any extraction still waiting for that set
  (`ExtractLearnerItemsJob.discard_waiting`). Deleting keeps no record. The page reads no
  `ConceptMastery`, and its fixed copy names no tier, score or level.
- **Retention.** `SweepLearnerNotesJob` (daily, `default`) first expires
  overdue open items under each owner's row lock, by the owner's local date
  (`closed_on` is the expiry date), then deletes notes past
  `LearnerNote::KEPT_FOR` by their set's date and closed items past
  `LearnerItem::KEPT_AFTER_CLOSE` after `closed_on`, so an inactive
  account's items still go. The privacy page reads
  both, the look-back window and the open-item limit from
  `PrivacyNotice.facts`, so a change to one changes the page. It shows the
  learner notes lines, and `stored.body_with_learner_notes` in place of
  `stored.body`, only while `LEARNER_NOTES` is on.
- **Duck turns in the extraction prompt** pass through `UserText.defanged`,
  so a duck reply carrying engineer tags never reads as the engineer's words.
