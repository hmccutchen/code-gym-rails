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
(`AccountData::FATES`, `deleting-an-account.md`). Until L2 ships, account
deletion is the only code that reads `user_id`, and it finds no rows to
delete. Shared rows have no `user_id`, so deletion leaves them alone until
L5 removes them.

## Order and deploy gates

The worker can start before the web service has migrated, so a new column
ships one release before any code reads it for Learn
(`.claude/rules/deployment.md`, Migrations). The change ships in five steps:

1. **L1, schema and deletion fate.** Adds a nullable `user_id` (foreign key
   to `users`) to both tables, unique indexes on `(user_id, concept,
   language)` and `(user_id, group_key)`, and turns the old unique indexes
   into partial ones over rows with no user, so code still in production
   keeps deduplicating shared rows. Deletion removes a user's own rows.
2. **L2, per-user concept references (done).** Reads and writes the
   user's own reference, falling back to the shared row when the user has
   none. Waits until L1 is deployed. L2 must also:
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
     code note, since deletion starts removing a person's write-ups here;
   - update the locale strings that say the wording is shared: Learn's
     `ladder_offer` and `lesson_offer`, and the bulk preparation copy
     (`prepare_cost`, `ladders_cost`) that says what it writes is shared with
     everyone on the team.
3. **L3, per-user recognition guides.** The same for guides, with the same
   obligations: scope `RecognitionGuide`'s `uniqueness: true` on `group_key`
   to `user_id`; key `GenerateRecognitionGuideJob`'s `limits_concurrency`
   (today `recognition_guide/<group_key>`, with discard) on `user_id` too;
   make its write survive a deletion mid-call, with the same spec, and add
   it to "Work in flight"; and update any privacy or locale copy that still
   calls a guide shared.
4. **L4, copy shared rows.** Copies every shared row to every active
   account. Waits until L2 (and L3 for guides) is deployed on both web and
   worker, so no old writer creates a shared row after the copy.
5. **L5, drop the shared fallback, then tighten the schema.** The pull
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
- The admin promote check counts any row, a teammate's included. It asks
  only whether the concept has ever been written up and shows no text, and
  a reference for a concept outside the vocabulary exists only once
  someone's set was tagged with it.
- Generating a set (a new one or a regeneration) queues the user's missing
  write-ups at `JobPriority::BULK` once the set is saved, leaving out a
  concept the set hides until it is submitted, so Learn never gains a
  write-up that hints at a hidden answer. Submitting still queues the rest.
- `User#writes_learn_content?` (it replaced `#prepares_ladders?`) gates
  every enqueue path and the job itself, so a trial account writes nothing.
- The preview seed writes the preview user's own row, never a shared one,
  so nothing writes a shared row after L2.
- Until L3b moves bulk work behind the scheduled sets, `JobPriority::BULK`
  still runs ahead of `JobPriority::SCHEDULED`, so the write-ups a morning
  set queues can run before later users' scheduled sets.

## The deploy window between L1 and L2

Railway does not order the web and worker deploys. While L2 rolls out, the
web service can still run L1 code after the L2 worker has written a user's
own row. L1 code looks a reference up by concept and language alone, so it
may show that row to another user as if it were shared. The text is a
generic concept explanation and holds nothing private, so this is accepted
for the length of one deploy.

## Rollback

L1 can be reverted only until L2 ships. Its `down` raises
`ActiveRecord::IrreversibleMigration` once either table holds a row with a
`user_id`: recreating the old full unique indexes would fail, and code from
before L2 would pick an arbitrary user's row by concept and language. After
L2 has written owned rows, the rollback floor is L2's code.
