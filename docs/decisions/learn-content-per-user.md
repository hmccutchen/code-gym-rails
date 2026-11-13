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
- **Existing shared rows are copied to every current user once, then
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
2. **L2, per-user concept references.** Reads and writes the user's own
   reference, falling back to the shared row when the user has none. Waits
   until L1 is deployed. L2 must also:
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
5. **L5, drop the shared fallback, then tighten the schema.** The code stops
   reading shared rows first. Immediately before the shared rows are
   removed, the L4 copy runs again for accounts created since L4, so nobody
   loses text they could see. A later migration then removes the shared
   rows, drops the partial indexes and makes `user_id` non-null.

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
