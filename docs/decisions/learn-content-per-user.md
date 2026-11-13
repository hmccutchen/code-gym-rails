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
  again.
- **The automatic write-up on submit stays.** Submitting a day still queues
  write-ups for the concepts it touched. Generating a set also queues them,
  so the text is ready sooner.
- **Bulk "prepare" jobs run behind the morning scheduled sets.** A bulk
  write-up never delays a user's daily set.
- **`script/junior_ladder_preparation.rb` is retired.** Per-user writing
  replaces what it prepared for everyone.
- **Trial accounts get no Learn content generation.** Trials are paused, so
  no trial account writes a reference or guide on the house key.
- **`SuggestedConcept` stays shared.** It is an admin queue of concept tags,
  not text a user reads.

## Account deletion

A user's own rows go when the account is deleted
(`AccountData::FATES`, `deleting-an-account.md`). Shared rows have no
`user_id`, so deletion leaves them alone until step L5 removes them.

## Order and deploy gates

The worker can start before the web service has migrated, so a new column
ships one release before any code reads it (`.claude/rules/deployment.md`,
Migrations). The change ships in five steps:

1. **L1, schema and deletion fate.** Adds a nullable `user_id` (foreign key
   to `users`) to both tables, unique indexes on `(user_id, concept,
   language)` and `(user_id, group_key)`, and turns the old unique indexes
   into partial ones over rows with no user, so code still in production
   keeps deduplicating shared rows. Deletion removes a user's own rows. No
   code reads the column.
2. **L2, per-user concept references.** Reads and writes the user's own
   reference, falling back to the shared row when the user has none. Waits
   until L1 is deployed.
3. **L3, per-user recognition guides.** The same for guides.
4. **L4, copy shared rows.** Copies every shared row to every current user.
   Waits until L2 (and L3 for guides) is deployed on both web and worker, so
   no old writer creates a shared row after the copy.
5. **L5, drop the shared fallback, then tighten the schema.** The code stops
   reading shared rows first; a later migration removes them, drops the
   partial indexes and makes `user_id` non-null.
