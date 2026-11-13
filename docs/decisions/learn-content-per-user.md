# Learn content belongs to each user

**Decision (2026-11-13, owner).** Concept references and recognition guides
become separate for each user. Until now `concept_references` (unique on
concept and language) and `recognition_guides` (unique on group key) were
shared: the first user whose key asked for a row paid for it, and every
teammate saw the same text. From now on each user owns their own rows,
written with their own key.

The owner decided:

- **Content is per user.** Each user has their own `ConceptReference` rows,
  keyed on user, concept and language.
- **Recognition guides are per user too**, keyed on user and group key.
- **Existing shared rows are copied to every current user, then
  removed.** Nobody loses text they can see today, and nobody pays for it
  again. The copy goes to active accounts only, never to an anonymized one.
- **The automatic write-up on submit stays.** Submitting a day still queues
  write-ups for the concepts it touched. Generating a set also queues them,
  so the text is ready sooner.
- **Bulk "prepare" jobs run behind the morning scheduled sets.** A bulk
  write-up never delays a user's daily set.
- **`script/junior_ladder_preparation.rb` is retired**, with
  `script/prepare_junior_ladders.rb`, the runner that loads it. Per-user
  writing replaces what it prepared for everyone.
- **Trial accounts get no Learn content generation.** Trials are paused, so
  no trial account writes a reference or guide on the house key.
- **`SuggestedConcept` stays shared.** It is an admin queue of concept tags,
  not text a user reads.

## Account deletion

A user's own rows go when the account is deleted
(`AccountData::FATES`, `deleting-an-account.md`). Since L2, every reference
read and write goes through `user_id`, so deletion finds the concept
references a user has written. Since L3 the same holds for recognition
guides. Shared rows have no
`user_id`, so deletion leaves them alone until L5 removes them.

## Order and deploy gates

The worker can start before the web service has migrated, so a new column
ships one release before any code reads it for Learn
(`.claude/rules/deployment.md`, Migrations). The change ships in six steps:

1. **L1, schema and deletion fate.** Adds a nullable `user_id` (foreign key
   to `users`) to both tables, unique indexes on `(user_id, concept,
   language)` and `(user_id, group_key)`, and turns the old unique indexes
   into partial ones over rows with no user, so code still in production
   keeps deduplicating shared rows. Deletion removes a user's own rows.
2. **L2, per-user concept references (done, apart from the privacy copy
   below).** Reads and writes the user's own reference, falling back to the
   shared row when the user has none. Waits until L1 is deployed. L2 must also:
   - scope `ConceptReference`'s `uniqueness: { scope: :language }` to
     `user_id`;
   - key `GenerateConceptReferenceJob`'s `limits_concurrency` on `user_id`
     as well as language and concept, since its `on_conflict: :discard`
     would otherwise drop another user's job for the same concept;
   - make the job's write survive the user being deleted during the
     provider call: check the user again under a lock before writing, write
     nothing if the account is gone, and never leave a failed job behind on
     `InvalidForeignKey`. A spec deletes the user between the provider call
     and the write. The job joins the "Work in flight" list in
     `deleting-an-account.md` in the same step;
   - update the privacy page copy (`privacy.show`) and the `PrivacyNotice`
     code note, since deletion starts removing a person's write-ups here.
     The privacy page is not on L2's base: it arrives with PR #785. These
     copy changes land in the first pull request opened after both #785
     and L2 are merged, so this item is still open;
   - update the locale strings that say the wording is shared: Learn's
     `ladder_offer` and `lesson_offer`, and the bulk preparation copy
     (`prepare_cost`, `ladders_cost`) that says what it writes is shared with
     everyone on the team.
3. **L3, per-user recognition guides (done, apart from any privacy copy,
   which follows the same note as L2's).** The same for guides, with the same
   obligations: scope `RecognitionGuide`'s `uniqueness: true` on `group_key`
   to `user_id`; key `GenerateRecognitionGuideJob`'s `limits_concurrency`
   (today `recognition_guide/<group_key>`, with discard) on `user_id` too;
   make its write survive a deletion mid-call, with the same spec, and add
   it to "Work in flight"; and update any privacy or locale copy that still
   calls a guide shared.
4. **L3b, scheduled sets ahead of Learn's bulk prepare.** Learn's
   prepare and prepare-ladders presses queue at `JobPriority::BULK`, ahead
   of `JobPriority::SCHEDULED`, so a press can still delay a morning set.
   L3b moves that click-driven bulk work behind the scheduled sets and
   lets a single-concept click jump the queue (issue #777). It needs no
   deploy gate.
5. **L4, copy shared rows.** Copies every shared row to every active
   account. Waits until L2 (and L3 for guides) is deployed on both web and
   worker, so no old writer creates a shared row after the copy.
6. **L5, drop the shared fallback, then tighten the schema.** The pull
   request that removes the fallback also carries a data migration that
   runs the L4 copy again for every active account still missing a copy.
   It runs in the web pre-deploy step, while the code still serving reads
   the shared rows, so every account that exists before the new code serves
   has its own copy first. Nobody loses text they could see. An account
   created during that deploy, after the copy and before the new code
   serves, gets no copy; it sees what any new account sees and generates
   its own. A later migration then removes the shared rows, drops the
   partial indexes and makes `user_id` non-null.

## What L2 does

- `ConceptReference.for(user, concept:, language:)` and
  `ConceptReference.seen_by(user, ...)` are the one answer to which
  reference a user sees: their own row, else the shared one, never another
  user's. Learn, the dashboard and History inline reference, the featured
  callout, the review's short version, generation's ladders
  (`GenerationLadders.for(user, ...)`), `LadderCoverage` and
  `explain_differently` read through them. L5 drops the shared half.
- `GenerateConceptReferenceJob` writes only the user's own row. A user with
  only the shared row who asks for a rewrite gets a new row of their own,
  numbered past the shared row's `generation_version` so the Learn poll sees
  the rewrite land; the shared row is never written again.
- The admin promote check (`ConceptReference.written_up?` and
  `.written_up_keys`) counts any row, a teammate's included. It asks
  only whether the concept has ever been written up and shows no text, and
  a reference for a concept outside the vocabulary exists only once
  someone's set was tagged with it.
- Generating a set (a new one or a regeneration) queues the user's missing
  write-ups at `JobPriority::BACKGROUND` once the set is saved, one step
  below the scheduled sets. At `JobPriority::SCHEDULED` they would have
  tied with the sets, and Solid Queue breaks a tie by job id, so a write-up
  from an earlier hour, or from early in the hourly hand-out, would have run
  ahead of a teammate's set enqueued after it. One step lower, they never
  delay a teammate's daily set. It leaves out a
  concept the set hides until it is submitted, so Learn never gains a
  write-up that hints at a hidden answer. Submitting still queues the rest.
- `User#writes_learn_content?` (it replaced `#prepares_ladders?`) gates
  every enqueue path and the job itself, so a trial account writes nothing.
- The preview seed writes the preview user's own row, never a shared one,
  so nothing writes a shared row after L2.
- Which pairs still lack a write-up is `ConceptReference.missing_for(user,
  pairs)`, asked by both Learn's prepare button and
  `GenerateConceptReferenceJob.queue_missing`.
- "Own wins" is decided per row, not per field. A user whose own row has no
  ladder sees that row, so a shared row's ladder for the same concept stays
  hidden from them until they refresh it or L5 removes the shared rows.
  Mixing fields from two rows would show a ladder written for different
  text, so this is accepted.
- Until L3b ships, Learn's bulk prepare presses still run at
  `JobPriority::BULK`, ahead of the scheduled sets.

## What L3 does

- `RecognitionGuide.seen_by(user, group_keys)` is the one answer to which
  guide a user sees: their own row, else the shared one, never another
  user's. Learn's index reads it, and `RecognitionGuide.missing_for(user,
  group_keys)` decides which guides the prepare button queues. No endpoint
  finds a guide by id, so there is no cross-user path to close. L5 drops
  the shared half.
- The uniqueness validation on `group_key` is scoped to `user_id`.
- `GenerateRecognitionGuideJob` keys its permit on user and group key. It
  skips the call when the user already sees a guide, their own or the
  shared one, since guides are never rewritten. It calls the provider
  outside any lock, then writes the user's own row inside a transaction that
  share-locks the user, and writes nothing once the account is gone. It
  never writes a shared row, and a trial account writes nothing
  (`User#writes_learn_content?`).
- Learn's `prepare_cost` copy no longer says the guides are shared.
- The recognition guide prompt is unchanged: it still takes only the group,
  and no exercise, response or history.

## The deploy window between L1 and L2

Railway does not order the web and worker deploys, so either service can
run L1 code while the other runs L2.

- **Web still on L1.** The web service can run L1 code after the L2 worker
  has written a user's own row. L1 code looks a reference up by concept and
  language alone, so it may show that row to another user as if it were
  shared. The text is a generic concept explanation and holds nothing
  private.
- **Worker still on L1.** An L1 worker can run a job the L2 web service
  queued. It also looks rows up by concept and language only, so it may
  skip a user's write-up because a teammate's row exists, rewrite a
  teammate's incomplete row from this user's call, or create a shared row
  with no `user_id`. A skipped write-up is queued again on the user's next
  submit or Learn press. A shared row written here is one the L4 copy
  picks up, and L4 waits until L2 is deployed on both web and worker, so
  no old writer creates a shared row after the copy.

Both cases last for the length of one deploy, so they are accepted.

## The deploy window between L2 and L3

L3 does for recognition guides what L2 did for concept references, so the
same window opens again, with either service on L2 while the other runs L3.

- **Worker still on L2.** An L2 worker can run a guide job the L3 web
  service queued. It checks `RecognitionGuide.exists?(group_key:)` across
  all users, so it may skip this user's guide because a teammate already has
  their own row. It may also create a shared row, with no `user_id`, paid for
  by this user's key. A skipped guide is queued again on the user's next
  Learn press. A shared row written here is one the L4 copy picks up.
- **Web still on L2.** An L2 web service reads guides by
  `where(group_key:)` alone, so after an L3 worker has written a user's own
  row it may show that row to a teammate, and its prepare press leaves out
  a guide a teammate owns. A guide teaches how to look for a kind of problem
  in general and holds nothing private.

Both cases last for the length of one deploy, so they are accepted. L4's
gate waits for L3 on both web and worker, as well as L2, so no old writer
creates a shared guide after the copy.

L4's copy, and L5's second run of it, must insert a user's copy only where
that user has no row yet: no `(user_id, concept, language)` for a reference
and no `(user_id, group_key)` for a guide (for example with `ON CONFLICT DO
NOTHING` on those unique indexes). Since L2 and L3, a user can already own
rows written with their key, and those stay as they are.

## Rollback

L1 can be reverted only until L2 ships. Its `down` raises
`ActiveRecord::IrreversibleMigration` once either table holds a row with a
`user_id`: recreating the old full unique indexes would fail, and code from
before L2 would pick an arbitrary user's row by concept and language. After
L2 has written owned rows, the rollback floor is L2's code.
